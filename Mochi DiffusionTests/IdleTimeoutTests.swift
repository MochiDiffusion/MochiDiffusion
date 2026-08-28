//
//  IdleTimeoutTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the session-level mechanism the idle watchdog is built on.
///
/// Deterministic and free of the queue, so the temporal part of the feature is
/// isolated to `IdleTimeoutQueueTests` below rather than spread through it.
struct GenerationStopReasonTests {

    @Test("A fresh session has not stopped")
    func freshSessionIsRunning() {
        let session = GenerationSession(requestID: UUID())

        #expect(!session.isCancelled)
        #expect(session.stopReason == nil)
    }

    /// Runtimes poll `isCancelled` and must not care why. The queue reads
    /// `stopReason` and must.
    @Test(
        "Both reasons stop the session; only the reason distinguishes them",
        arguments: [GenerationSession.StopReason.cancelled, .expired]
    )
    func bothReasonsStop(reason: GenerationSession.StopReason) {
        let session = GenerationSession(requestID: UUID())

        if reason == .cancelled { session.cancel() } else { session.expire() }

        #expect(session.isCancelled)
        #expect(session.stopReason == reason)
    }

    @Test("The first reason wins and the second is a no-op")
    func firstReasonWins() {
        let expired = GenerationSession(requestID: UUID())
        #expect(expired.expire())
        #expect(!expired.cancel())
        #expect(expired.stopReason == .expired)

        let cancelled = GenerationSession(requestID: UUID())
        #expect(cancelled.cancel())
        #expect(!cancelled.expire())
        #expect(cancelled.stopReason == .cancelled)
    }

    /// Expiry has to fire the handlers too. Iris only stops when
    /// `iris_request_cancel()` sets the library's own flag, and a stalled request
    /// needs that poke exactly as much as a cancelled one.
    @Test("Expiry runs the cancellation handlers, once")
    func expiryRunsHandlers() {
        let session = GenerationSession(requestID: UUID())
        let pokes = Counter()
        session.onCancel { pokes.increment() }

        session.expire()
        session.expire()
        session.cancel()

        #expect(pokes.value == 1)
    }

    @Test("A handler registered after the session stopped runs immediately")
    func lateHandlerRunsImmediately() {
        let session = GenerationSession(requestID: UUID())
        let pokes = Counter()
        session.expire()

        session.onCancel { pokes.increment() }

        #expect(pokes.value == 1)
    }

    @Test("Activity resets the idle clock")
    func activityResetsIdleClock() async throws {
        let session = GenerationSession(requestID: UUID())
        try await Task.sleep(for: .milliseconds(40))
        let beforeReset = session.idleDuration

        session.noteActivity()

        #expect(beforeReset >= .milliseconds(30))
        #expect(session.idleDuration < beforeReset)
    }

    @Test("Emitting an event counts as activity")
    func emitCountsAsActivity() async throws {
        let session = GenerationSession(requestID: UUID())
        try await Task.sleep(for: .milliseconds(40))
        let beforeEmit = session.idleDuration

        session.emit(.progress(GenerationState.Progress(step: 1, stepCount: 4)))

        #expect(session.idleDuration < beforeEmit)
    }

    /// A counter usable from a `@Sendable` handler without an actor hop, since
    /// the handlers run synchronously on whichever thread stopped the session.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
}

/// Pins that a runtime which goes quiet is given up on, and — the part that
/// matters — that giving up releases the drain exactly as a completion does.
///
/// A failure path that leaves the queue unable to start again is the bug class
/// `QueueLivenessTests` exists for; this is the same hazard reached by a new
/// route.
///
/// `.serialized` because `GenerationState` is a main-actor singleton, and a time
/// limit because a regression here hangs rather than fails.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct IdleTimeoutQueueTests {

    /// Runs, reports nothing, and waits to be stopped — as a real runtime does
    /// between steps. Never returns on its own, so only the watchdog ends it.
    struct StallingRuntime: GenerationEngineRuntime {
        let started: QueueLivenessTests.RunSignal
        let timeout: Duration

        var idleTimeout: Duration? { timeout }

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            await started.signal()
            while !session.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// Reports steadily for longer than the timeout, but never idles that long.
    /// The distinction between an idle bound and a wall-clock budget, as a test.
    struct HeartbeatRuntime: GenerationEngineRuntime {
        let started: QueueLivenessTests.RunSignal
        let timeout: Duration
        let beats: Int
        let interval: Duration

        var idleTimeout: Duration? { timeout }

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            await started.signal()
            for step in 0..<beats {
                session.emit(
                    .progress(GenerationState.Progress(step: step, stepCount: beats))
                )
                try? await Task.sleep(for: interval)
            }
        }
    }

    struct TimedEngine: GenerationEngineDescriptor {
        typealias Model = QueueLivenessTests.SignallingEngine.Model
        typealias Payload = QueueLivenessTests.SignallingEngine.Payload

        static let id = EngineID(rawValue: "timed")
        let makeIt: @Sendable () -> any GenerationEngineRuntime
        var displayName: String { "Timed" }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }
        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] { [] }

        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            throw GenerationError.pipelineNotAvailable
        }

        func makeRuntime() -> any GenerationEngineRuntime { makeIt() }
    }

    private func makeRequest(prompt: String) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: TimedEngine.id, key: "model"),
            displayName: "model",
            metadataFields: [.prompt],
            payload: QueueLivenessTests.SignallingEngine.Payload(),
            prompt: prompt,
            negativePrompt: "",
            size: CGSize(width: 64, height: 64),
            startingImageData: nil,
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: nil,
            stepCount: nil,
            guidanceScale: nil,
            scheduler: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 1,
            numberOfImages: 1,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
        )
    }

    private func makeService(
        _ runtime: @escaping @Sendable () -> any GenerationEngineRuntime
    ) -> GenerationService {
        GenerationService(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(TimedEngine(makeIt: runtime))
            ])
        )
    }

    private func waitForState(
        _ matches: @escaping @Sendable (GenerationState.Status) -> Bool
    ) async {
        while !(await MainActor.run { matches(GenerationState.shared.state) }) {
            await Task.yield()
        }
    }

    @Test("A runtime that goes quiet is given up on and reported")
    func stalledRuntimeExpires() async throws {
        await MainActor.run { GenerationState.shared.state = .ready(nil) }
        let started = QueueLivenessTests.RunSignal()
        let service = makeService {
            StallingRuntime(started: started, timeout: .milliseconds(300))
        }

        await service.enqueue(makeRequest(prompt: "stalls"))
        await started.wait(untilRuns: 1)

        // Reported as an error rather than going quietly `.ready`, and honest that
        // a remote service may still bill for it.
        await waitForState { status in
            if case .error(let message) = status {
                return message.contains("Stopped waiting")
                    && message.contains("charge")
            }
            return false
        }
    }

    /// The hazard. An expiry that failed to release the drain would leave every
    /// later request accepted and never started — the `dc209e9` failure mode,
    /// reached by a different route.
    @Test("A request enqueued after an expiry still runs")
    func drainSurvivesAnExpiry() async throws {
        await MainActor.run { GenerationState.shared.state = .ready(nil) }
        let started = QueueLivenessTests.RunSignal()
        let service = makeService {
            StallingRuntime(started: started, timeout: .milliseconds(300))
        }

        await service.enqueue(makeRequest(prompt: "stalls"))
        await started.wait(untilRuns: 1)
        await waitForState { status in
            if case .error = status { return true }
            return false
        }

        await service.enqueue(makeRequest(prompt: "after the expiry"))
        await started.wait(untilRuns: 2)

        #expect(await started.runCount == 2)
    }

    /// Total duration well past the timeout, no single gap anywhere near it. A
    /// wall-clock budget would fail this; an idle bound must not.
    @Test("A runtime reporting steadily is not given up on")
    func heartbeatingRuntimeSurvives() async throws {
        await MainActor.run { GenerationState.shared.state = .ready(nil) }
        let started = QueueLivenessTests.RunSignal()
        let service = makeService {
            HeartbeatRuntime(
                started: started,
                timeout: .milliseconds(400),
                beats: 12,
                interval: .milliseconds(60)
            )
        }

        await service.enqueue(makeRequest(prompt: "reports"))
        await started.wait(untilRuns: 1)

        // Finishes normally: 720ms of work, never 400ms of silence.
        await waitForState { $0 == .ready(nil) }
    }

    @Test("A local runtime declares no idle timeout")
    func localRuntimesHaveNoTimeout() {
        #expect(CoreMLEngineRuntime().idleTimeout == nil)
        #expect(IrisEngineRuntime().idleTimeout == nil)
    }
}
