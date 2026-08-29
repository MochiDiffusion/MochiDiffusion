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
/// The queue used to refuse to start unless `GenerationState` was `.ready`, and
/// nothing outside `GenerationService` ever restores `.ready`. So one failure that
/// left `.error` — an unwritable images folder, say — stranded every later request
/// permanently: the button stayed enabled, the request was appended, and no drain
/// would ever start. These tests exist so that cannot come back.
///
/// `.serialized` and a time limit because `GenerationState` and `ImageGallery` are
/// main-actor singletons, and because a regression here hangs rather than fails.
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

    private func makeRequest(prompt: String = "a cat") -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: SignallingEngine.id, key: "model"),
            displayName: "model",
            metadataFields: [.prompt],
            payload: SignallingEngine.Payload(),
            prompt: prompt,
            negativePrompt: "",
            size: CGSize(width: 64, height: 64),
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
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
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

    /// The regression. Every non-`.ready` state used to strand the request; only
    /// `.error` did so permanently, because the other states imply a drain is
    /// already running.
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

    /// A distinct property from the one above: the state guard was only ever at
    /// the top of the drain, so an error part-way through a batch never stopped the
    /// rest of it. Verified by restoring the guard — this test still passed, which
    /// is why it is not the regression pin.
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

    /// Back-to-back enqueues, which is the ordinary path rather than the narrow
    /// one.
    ///
    /// The teardown race the outer loop in `processQueue` fixes — a request landing
    /// after the inner loop exits but before `processingTask` is cleared — is
    /// **not** pinned here, and this test passes with or without that fix. Hitting
    /// the window needs the queue-empty notification to be slow on demand, and
    /// `NotificationController.shared` is a singleton with no seam. Left as a
    /// known gap rather than a test that implies coverage it does not have.
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
        // afterwards was racy: `GenerationState` is a singleton, and a service
        // from an earlier test that is still finishing can write to it between the
        // loop exiting and the check. That failed about one isolated run in three.
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
}
