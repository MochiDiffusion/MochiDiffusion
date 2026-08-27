//
//  GenerationSessionTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import Mochi_Diffusion

/// Pins the contract the engine runtimes rely on: cancellation that a blocked
/// runtime cannot swallow, and events that stop flowing the moment a request is
/// over.
struct GenerationSessionTests {
    private func makeSession() -> GenerationSession {
        GenerationSession(requestID: UUID())
    }

    // MARK: - Cancellation

    @Test("A session starts uncancelled and stays cancelled once cancelled")
    func cancellationIsSticky() {
        let session = makeSession()

        #expect(!session.isCancelled)
        #expect(session.cancel())
        #expect(session.isCancelled)
    }

    /// The return value is what lets a caller avoid repeating the side effects of
    /// cancelling — broadcasting a snapshot, moving the UI to `.canceling`.
    @Test("Only the first cancel reports that it changed anything")
    func cancellationIsIdempotent() {
        let session = makeSession()

        #expect(session.cancel())
        #expect(!session.cancel())
        #expect(!session.cancel())
    }

    /// Iris cannot poll: its loop is inside a C call that only stops when the
    /// library's own flag is set, and the runtime is inside that call.
    @Test("A cancellation handler runs when the session is cancelled")
    func cancellationHandlerRuns() {
        let session = makeSession()
        let poked = Mutex(false)

        session.onCancel { poked.withLock { $0 = true } }
        #expect(!poked.withLock { $0 })

        session.cancel()
        #expect(poked.withLock { $0 })
    }

    /// A runtime registers its handler after cancellation has already been
    /// requested if the user cancels while the model is still loading. Running it
    /// immediately is what stops that cancel from being lost.
    @Test("A handler registered after cancellation runs immediately")
    func lateHandlerRunsImmediately() {
        let session = makeSession()
        session.cancel()

        let poked = Mutex(false)
        session.onCancel { poked.withLock { $0 = true } }

        #expect(poked.withLock { $0 })
    }

    @Test("Each handler runs once, however many times cancel is called")
    func handlersRunOnce() {
        let session = makeSession()
        let count = Mutex(0)

        session.onCancel { count.withLock { $0 += 1 } }
        session.cancel()
        session.cancel()

        #expect(count.withLock { $0 } == 1)
    }

    @Test("Closing a session drops handlers that never fired")
    func closeDropsHandlers() {
        let session = makeSession()
        let poked = Mutex(false)
        session.onCancel { poked.withLock { $0 = true } }

        session.close()
        session.cancel()

        #expect(!poked.withLock { $0 })
    }

    // MARK: - Events

    @Test("Events arrive in the order they were emitted")
    func eventsPreserveOrder() async {
        let session = makeSession()

        session.emit(.state(.loading("one")))
        session.emit(.progress(GenerationState.Progress(step: 0, stepCount: 4)))
        session.emit(.progress(GenerationState.Progress(step: 1, stepCount: 4)))
        session.close()

        var steps: [Int] = []
        var labels: [String] = []
        for await event in session.events {
            switch event {
            case .state(.loading(let label)):
                labels.append(label ?? "")
            case .progress(let progress):
                steps.append(progress.step)
            default:
                break
            }
        }

        #expect(labels == ["one"])
        #expect(steps == [0, 1])
    }

    /// The single checkpoint a late event is dropped at. Without it, an Iris C
    /// callback firing during teardown reports the finished request's progress
    /// against whatever runs next.
    @Test("Events emitted after close are dropped")
    func eventsAfterCloseAreDropped() async {
        let session = makeSession()

        session.emit(.progress(GenerationState.Progress(step: 0, stepCount: 4)))
        session.close()
        session.emit(.progress(GenerationState.Progress(step: 99, stepCount: 4)))
        session.emit(.state(.loading("too late")))

        var received: [Int] = []
        for await event in session.events {
            if case .progress(let progress) = event {
                received.append(progress.step)
            }
        }

        #expect(received == [0])
    }

    @Test("Closing ends the stream so a drain loop finishes")
    func closeEndsTheStream() async {
        let session = makeSession()
        session.close()

        var count = 0
        for await _ in session.events {
            count += 1
        }

        #expect(count == 0)
    }
}

/// Pins that the Iris C callbacks reach the session that is generating, and
/// nothing else. The C API has no context pointer, so this routing is the only
/// thing standing between a teardown callback and the next request.
struct IrisCallbackRoutingTests {
    private func drain(_ session: GenerationSession) async -> [GenerationEvent] {
        session.close()
        var events: [GenerationEvent] = []
        for await event in session.events {
            events.append(event)
        }
        return events
    }

    @Test("Progress reaches the session that is generating")
    func progressReachesActiveSession() async {
        let router = IrisCallbackRouter()
        let session = GenerationSession(requestID: UUID())
        router.begin(session: session, usePreview: false)

        router.report(progress: 3, total: 4)

        let events = await drain(session)
        // Iris counts from one, the UI from zero.
        #expect(events.count == 1)
        if case .progress(let progress) = events.first {
            #expect(progress.step == 2)
            #expect(progress.stepCount == 4)
        } else {
            Issue.record("expected a progress event, got \(events)")
        }
    }

    @Test("A zero total is ignored rather than reported as impossible progress")
    func zeroTotalIsIgnored() async {
        let router = IrisCallbackRouter()
        let session = GenerationSession(requestID: UUID())
        router.begin(session: session, usePreview: false)

        router.report(progress: 0, total: 0)

        #expect(await drain(session).isEmpty)
    }

    @Test("Nothing is delivered once the session has ended")
    func nothingAfterEnd() async {
        let router = IrisCallbackRouter()
        let session = GenerationSession(requestID: UUID())
        router.begin(session: session, usePreview: true)
        router.end(session: session)

        router.report(progress: 1, total: 4)
        router.report(phase: "encoding text", done: 0)
        router.report(preview: nil)

        #expect(await drain(session).isEmpty)
    }

    /// If a finishing request tore down the route by identity-free reset, it would
    /// silently mute the request that had already started.
    @Test("An outgoing session ending does not detach the one that replaced it")
    func endOnlyAffectsItsOwnSession() async {
        let router = IrisCallbackRouter()
        let finishing = GenerationSession(requestID: UUID())
        let starting = GenerationSession(requestID: UUID())

        router.begin(session: finishing, usePreview: false)
        router.begin(session: starting, usePreview: false)
        // Arrives late, after the next request already installed its own route.
        router.end(session: finishing)

        router.report(progress: 1, total: 4)

        #expect(await drain(finishing).isEmpty)
        #expect(await drain(starting).count == 1)
    }

    @Test("Previews are dropped when the request did not ask for them")
    func previewsHonourTheRequest() async {
        let router = IrisCallbackRouter()
        let without = GenerationSession(requestID: UUID())
        router.begin(session: without, usePreview: false)
        router.report(preview: makeCGImage())
        #expect(await drain(without).isEmpty)

        let with = GenerationSession(requestID: UUID())
        router.begin(session: with, usePreview: true)
        router.report(preview: makeCGImage())
        #expect(await drain(with).count == 1)
    }

    @Test("An unfinished phase becomes a loading label, a finished one is ignored")
    func phaseLabels() async {
        let router = IrisCallbackRouter()
        let session = GenerationSession(requestID: UUID())
        router.begin(session: session, usePreview: false)

        router.report(phase: "encoding text", done: 0)
        router.report(phase: "encoding text", done: 1)
        router.report(phase: nil, done: 0)

        let events = await drain(session)
        #expect(events.count == 1)
        if case .state(.loading(let label)) = events.first {
            #expect(label == "Encoding prompt...")
        } else {
            Issue.record("expected a loading state, got \(events)")
        }
    }
}
