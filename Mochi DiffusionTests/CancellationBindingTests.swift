//
//  CancellationBindingTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins *which* request a stop reaches, and that reaching it does not depend on
/// the main actor being free.
///
/// `GenerationService` is a reentrant actor, so a stop must bind to the running
/// session before any hop to the main actor, during which the next request could
/// start.
///
/// An extension of `QueueLivenessTests` rather than a suite of its own: both drive
/// `GenerationService`, which writes to the `GenerationState` singleton, and two
/// separately `.serialized` suites are not serialized against each other.
extension QueueLivenessTests {

    /// The sessions the fake runtime was handed, by request prompt.
    actor SessionLog {
        private var sessions: [String: GenerationSession] = [:]

        func record(_ session: GenerationSession, for prompt: String) {
            sessions[prompt] = session
        }

        func session(for prompt: String) -> GenerationSession? { sessions[prompt] }
    }

    /// Lets a test end a fake run that is not being cancelled.
    actor ReleaseGate {
        private var released: Set<String> = []

        func release(_ prompt: String) { released.insert(prompt) }
        func isReleased(_ prompt: String) -> Bool { released.contains(prompt) }
    }

    /// Records the session it is given, then keeps running until that session is
    /// stopped or the test releases it — which is what a real runtime does between
    /// steps, and what makes a request observable while it is current.
    struct RecordingRuntime: GenerationEngineRuntime {
        let sessions: SessionLog
        let started: RunSignal
        let releases: ReleaseGate

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            // Recorded before signalling, so a test that has been told the request
            // started can always find its session.
            await sessions.record(session, for: request.prompt)
            await started.signal()
            while !session.isCancelled, !(await releases.isReleased(request.prompt)) {
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    /// Occupies the main actor until released.
    ///
    /// Blocks its thread on purpose: an `await` would hand the main actor back,
    /// and the point is to hold it the way a busy UI does. The wait is bounded, so
    /// a failure is an expectation instead of a hang.
    final class MainActorHold: @unchecked Sendable {
        private let condition = NSCondition()
        private var isOpen = false
        private var isHolding = false

        func hold() {
            condition.lock()
            isHolding = true
            condition.broadcast()
            let deadline = Date().addingTimeInterval(10)
            while !isOpen, condition.wait(until: deadline) {}
            isHolding = false
            condition.unlock()
        }

        /// Whether the main actor is occupied *right now*. Read after the
        /// assertion it qualifies, to show the stop did not simply win a race
        /// against a hold that had already ended.
        var holdsMainActor: Bool {
            condition.lock()
            defer { condition.unlock() }
            return isHolding
        }

        func release() {
            condition.lock()
            isOpen = true
            condition.broadcast()
            condition.unlock()
        }
    }

    private func makeRecordingService(
        sessions: SessionLog,
        started: RunSignal,
        releases: ReleaseGate
    ) -> GenerationService {
        GenerationService(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(
                    TimedEngine {
                        RecordingRuntime(sessions: sessions, started: started, releases: releases)
                    }
                )
            ]),
            imageGallery: ImageGallery()
        )
    }

    private func makeRecordingRequest(prompt: String) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: TimedEngine.id, key: "model"),
            displayName: "model",
            metadataFields: [.prompt],
            payload: SignallingEngine.Payload(),
            prompt: prompt,
            negativePrompt: "",
            size: CGSize(width: 64, height: 64),
            startingImageData: nil,
            inputImageData: [],
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: nil,
            stepCount: nil,
            guidanceScale: nil,
            scheduler: nil,
            quality: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 1,
            numberOfImages: 1,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
        )
    }

    /// Polls `condition` for up to `timeout`, so a failure is an expectation
    /// rather than a hang.
    private func wait(
        upTo timeout: Duration = .seconds(3),
        for condition: @Sendable () -> Bool
    ) async throws {
        var waited = Duration.zero
        while !condition(), waited < timeout {
            try await Task.sleep(for: .milliseconds(2))
            waited += .milliseconds(2)
        }
    }

    /// The main actor is busy exactly when a generation is running, so the stop
    /// must not wait for it.
    @Test("A stop reaches the running session without waiting on the main actor")
    func stopDoesNotWaitOnTheMainActor() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let started = RunSignal()
        let sessions = SessionLog()
        let releases = ReleaseGate()
        let service = makeRecordingService(
            sessions: sessions, started: started, releases: releases
        )

        await service.enqueue(makeRecordingRequest(prompt: "running"))
        await started.wait(untilRuns: 1)
        let running = try #require(await sessions.session(for: "running"))

        let hold = MainActorHold()
        let holding = Task { @MainActor in hold.hold() }
        try await wait { hold.holdsMainActor }
        #expect(hold.holdsMainActor)

        let stop = Task { await service.stopCurrentGeneration() }
        try await wait { running.isCancelled }

        #expect(running.isCancelled)
        // The stop arrived while the main actor was still occupied, which is the
        // property: the flag is not behind the status update.
        #expect(hold.holdsMainActor)

        hold.release()
        await holding.value
        await stop.value
        await releases.release("running")
        await waitUntilIdle(service)
    }

    /// The acceptance criterion: the request the user chose to stop is the one
    /// that stops, and the queue keeps going.
    ///
    /// This does not force the race: that needs the drain's hop to the main actor
    /// to overtake the stop's, which the test's scheduling does not produce. The
    /// test above covers the ordering; this one states the property it protects.
    @Test("Stopping a request cannot cancel the one that follows it")
    func stopDoesNotReachTheNextRequest() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let started = RunSignal()
        let sessions = SessionLog()
        let releases = ReleaseGate()
        let service = makeRecordingService(
            sessions: sessions, started: started, releases: releases
        )

        await service.enqueue(makeRecordingRequest(prompt: "first"))
        await service.enqueue(makeRecordingRequest(prompt: "second"))
        await started.wait(untilRuns: 1)
        let first = try #require(await sessions.session(for: "first"))

        await service.stopCurrentGeneration()
        #expect(first.isCancelled)

        // Cancelled, so the first run ends on its own and the second starts.
        await started.wait(untilRuns: 2)
        let second = try #require(await sessions.session(for: "second"))

        #expect(!second.isCancelled)
        #expect(second.requestID != first.requestID)

        await releases.release("second")
        await waitUntilIdle(service)
    }
}
