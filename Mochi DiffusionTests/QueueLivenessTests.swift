//
//  QueueLivenessTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins that a queued request always runs.
///
/// Nothing outside `GenerationService` restores `GenerationState` to `.ready`, so
/// a queue that gated on it would strand every request after one failure.
///
/// `.serialized` because `GenerationState` is a main-actor singleton, and a time
/// limit because a failure here hangs rather than fails.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QueueLivenessTests {

    /// One-shot signal a fake runtime fires when it is asked to run.
    ///
    /// An actor rather than a lock because the test awaits it; nothing here is
    /// called from a synchronous C callback.
    actor RunSignal {
        private var runs = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func signal() {
            runs += 1
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        /// Suspends until `signal()` has been called at least `count` times.
        func wait(untilRuns count: Int) async {
            while runs < count {
                await withCheckedContinuation { waiters.append($0) }
            }
        }

        var runCount: Int { runs }
    }

    /// Runs and returns, reporting nothing. Enough to observe that the queue
    /// started the request, which is what these tests are about.
    struct SignallingRuntime: GenerationEngineRuntime {
        let signal: RunSignal

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            await signal.signal()
        }
    }

    struct SignallingEngine: GenerationEngineDescriptor {
        struct Model: EngineModel {
            let id: ModelID
            let url: URL
            let name: String
            var constraints: OptionConstraints { .unconstrained }
            var metadataFields: Set<MetadataField> { [.prompt] }
            var tokenizerModelDir: URL? { nil }
        }
        struct Payload: Sendable {}

        static let id = EngineID(rawValue: "signalling")
        let signal: RunSignal
        var displayName: String { "Signalling" }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] { [] }

        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            GenerationPlan(
                payload: Payload(),
                size: CGSize(width: 64, height: 64),
                startingImageData: nil,
                inputImageData: [],
                controlNetImageData: [],
                controlNetNames: [],
                controlNetImageNames: [],
                stepCount: 1,
                scheduler: .pndmScheduler,
                strength: nil,
                guidanceScale: nil,
                numberOfImages: 1,
                mlComputeUnit: nil,
                startingImageName: nil,
                inputImageNames: []
            )
        }

        func makeRuntime() -> any GenerationEngineRuntime {
            SignallingRuntime(signal: signal)
        }
    }

    private func makeRequest(
        prompt: String = "a cat",
        engine: EngineID = SignallingEngine.id,
        payload: any Sendable = SignallingEngine.Payload()
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: engine, key: "model"),
            displayName: "model",
            metadataFields: [.prompt],
            payload: payload,
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
            strength: 0.75,
            stepCount: 1,
            guidanceScale: nil,
            scheduler: .pndmScheduler,
            quality: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 1,
            numberOfImages: 1,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false)
        )
    }

    private func makeService(signal: RunSignal) -> GenerationService {
        GenerationService(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(SignallingEngine(signal: signal))
            ]),
            // Its own gallery, so this suite cannot disturb another's.
            imageGallery: ImageGallery()
        )
    }

    @Test(
        "A queued request runs whatever state the UI was left in",
        arguments: [
            GenerationState.Status.error("an earlier failure"),
            .ready("a message"),
            .canceling(nil),
        ]
    )
    func requestRunsFromAnyUIState(state: GenerationState.Status) async throws {
        await MainActor.run { GenerationState.shared.report(state) }
        let signal = RunSignal()
        let service = makeService(signal: signal)

        await service.enqueue(makeRequest())
        await signal.wait(untilRuns: 1)

        #expect(await signal.runCount == 1)
    }

    @Test("An error part-way through a batch does not stop the rest of it")
    func errorMidBatchDoesNotStopTheRest() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let signal = RunSignal()
        let service = makeService(signal: signal)

        await service.enqueue(makeRequest(prompt: "first"))
        await signal.wait(untilRuns: 1)

        // Whatever the first request left behind — here forced, since the fake
        // runtime cannot fail — must not stop the second.
        await MainActor.run { GenerationState.shared.report(.error("left over")) }

        await service.enqueue(makeRequest(prompt: "second"))
        await signal.wait(untilRuns: 2)

        #expect(await signal.runCount == 2)
    }

    /// Back-to-back enqueues, the ordinary path.
    ///
    /// Does not cover the teardown window the outer loop in `processQueue` handles
    /// — a request landing after the inner loop exits but before `processingTask`
    /// is cleared. Reaching it would need a slow queue-empty notification, and
    /// `NotificationController.shared` has no seam for that.
    @Test("Back-to-back requests both run")
    func backToBackRequestsBothRun() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let signal = RunSignal()
        let service = makeService(signal: signal)

        // Enqueued back to back so the second lands while the first is still being
        // processed or torn down, rather than after the drain has fully finished.
        await service.enqueue(makeRequest(prompt: "first"))
        await service.enqueue(makeRequest(prompt: "second"))

        await signal.wait(untilRuns: 2)

        #expect(await signal.runCount == 2)
    }

    @Test("A successful drain leaves the UI ready")
    func drainRestoresReady() async throws {
        await MainActor.run { GenerationState.shared.report(.error("an earlier failure")) }
        let signal = RunSignal()
        let service = makeService(signal: signal)

        await service.enqueue(makeRequest())
        await signal.wait(untilRuns: 1)

        // The drain sets the terminal state after the runtime returns, so the stale
        // error heals rather than needing anything outside the service to clear it.
        //
        // Reaching the end of the wait *is* the assertion. Re-reading the state
        // afterwards would race: a service from an earlier test that is still
        // finishing can write to the singleton between the loop and the check.
        while await MainActor.run(
            resultType: Bool.self, body: { GenerationState.shared.state != .ready(nil) })
        {
            await Task.yield()
        }
        await waitUntilIdle(service)
    }

    /// Waits until `service` has nothing running and nothing queued.
    ///
    /// Tests share the `GenerationState` singleton, and a test that returns while
    /// its own service is still finishing leaves that service's terminal writes to
    /// land during the *next* test. Draining before returning is what keeps one
    /// test's tail out of the next one's assertions.
    func waitUntilIdle(_ service: GenerationService) async {
        let stream = await service.updates()
        for await snapshot in stream {
            if snapshot.current == nil, snapshot.queue.isEmpty { return }
        }
    }

    // MARK: - Queue drained

    /// What recording runtimes were asked to do, in order.
    actor EventLog {
        private(set) var events: [String] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func record(_ event: String) {
            events.append(event)
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        /// Suspends until at least `count` events have been recorded.
        func wait(untilCount count: Int) async {
            while events.count < count {
                await withCheckedContinuation { waiters.append($0) }
            }
        }
    }

    /// Holds the first run open until the test has queued everything it needs.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        func pass() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    struct DrainRecordingRuntime: GenerationEngineRuntime {
        let name: String
        let log: EventLog
        let gate: Gate

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            await gate.pass()
            await log.record("\(name) run")
        }

        func queueDrained() async {
            await log.record("\(name) drained")
        }
    }

    protocol RecordingEngineName {
        static var name: String { get }
    }
    enum First: RecordingEngineName { static let name = "first" }
    enum Second: RecordingEngineName { static let name = "second" }

    struct RecordingEngine<Name: RecordingEngineName>: GenerationEngineDescriptor {
        struct Model: EngineModel {
            let id: ModelID
            let url: URL
            let name: String
            var constraints: OptionConstraints { .unconstrained }
            var metadataFields: Set<MetadataField> { [.prompt] }
            var tokenizerModelDir: URL? { nil }
        }
        struct Payload: Sendable {}

        static var id: EngineID { EngineID(rawValue: Name.name) }
        let log: EventLog
        let gate: Gate
        var displayName: String { Name.name }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] { [] }

        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            throw EngineError.payloadDoesNotBelongToEngine(engine: Self.id)
        }

        func makeRuntime() -> any GenerationEngineRuntime {
            DrainRecordingRuntime(name: Name.name, log: log, gate: gate)
        }
    }

    private func makeRecordingService(log: EventLog, gate: Gate) -> GenerationService {
        GenerationService(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(RecordingEngine<First>(log: log, gate: gate)),
                AnyGenerationEngine(RecordingEngine<Second>(log: log, gate: gate)),
            ]),
            imageGallery: ImageGallery()
        )
    }

    @Test("The queue reports itself drained once, after its last request")
    func drainedOnceAfterTheLastRequest() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let log = EventLog()
        let gate = Gate()
        let service = makeRecordingService(log: log, gate: gate)

        await service.enqueue(
            makeRequest(
                engine: RecordingEngine<First>.id, payload: RecordingEngine<First>.Payload())
        )
        await service.enqueue(
            makeRequest(
                engine: RecordingEngine<First>.id, payload: RecordingEngine<First>.Payload())
        )
        await gate.open()

        await log.wait(untilCount: 3)
        await waitUntilIdle(service)
        #expect(await log.events == ["first run", "first run", "first drained"])
    }

    @Test("A runtime hears the queue is drained for it when the next request is another engine's")
    func drainedWhenTheNextRequestIsAnotherEngines() async throws {
        await MainActor.run { GenerationState.shared.report(.ready(nil)) }
        let log = EventLog()
        let gate = Gate()
        let service = makeRecordingService(log: log, gate: gate)

        await service.enqueue(
            makeRequest(
                engine: RecordingEngine<First>.id, payload: RecordingEngine<First>.Payload())
        )
        await service.enqueue(
            makeRequest(
                engine: RecordingEngine<Second>.id, payload: RecordingEngine<Second>.Payload())
        )
        await gate.open()

        await log.wait(untilCount: 4)
        await waitUntilIdle(service)
        #expect(
            await log.events == ["first run", "first drained", "second run", "second drained"]
        )
    }
}
