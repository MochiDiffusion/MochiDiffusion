//
//  GenerationResultPathTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins what happens to a finished image: `GenerationService` writes it to the
/// images folder, emits it with its saved location, and the generation controller
/// inserts it into the gallery. A write that fails must fail the generation.
///
/// `.serialized` because `GenerationService` reports to the `GenerationState`
/// singleton, and a time limit because a failure here hangs rather than fails.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct GenerationResultPathTests {

    /// Collects values from concurrent callers and lets a test wait for them.
    actor Recorder<Value: Sendable> {
        private(set) var values: [Value] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func record(_ value: Value) {
            values.append(value)
            for waiter in waiters {
                waiter.resume()
            }
            waiters = []
        }

        /// Suspends until at least `count` values have been recorded.
        func wait(forCount count: Int) async {
            while values.count < count {
                await withCheckedContinuation { waiters.append($0) }
            }
        }
    }

    /// Runs each request through `body`, so one runtime can behave differently
    /// per request. The queue makes one runtime per engine and keeps it.
    struct ScriptedRuntime: GenerationEngineRuntime {
        let runs: Recorder<GenerationRequest.ID>
        let body:
            @Sendable (
                GenerationRequest,
                @escaping @Sendable (GenerationResult) async throws -> Void
            ) async throws -> Void

        func run(
            request: GenerationRequest,
            session: GenerationSession,
            onResult: @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws {
            await runs.record(request.id)
            try await body(request, onResult)
        }
    }

    struct ScriptedEngine: GenerationEngineDescriptor {
        struct Model: EngineModel {
            let id: ModelID
            let url: URL
            let name: String
            var constraints: OptionConstraints { .unconstrained }
            var metadataFields: Set<MetadataField> { [.prompt, .seed] }
            var tokenizerModelDir: URL? { nil }
        }
        struct Payload: Sendable {}
        struct NotPlanned: Error {}

        static let id = EngineID(rawValue: "scripted")
        let runtime: ScriptedRuntime
        var displayName: String { "Scripted" }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] { [] }

        /// Requests are built by hand, so nothing plans through this engine.
        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            throw NotPlanned()
        }

        func makeRuntime() -> any GenerationEngineRuntime { runtime }
    }

    /// A payload no registered engine owns.
    struct ForeignPayload: Sendable {}

    private let temp: TempDirectory
    private let imageDir: URL
    private let runs = Recorder<GenerationRequest.ID>()
    private let notifiedCounts = Recorder<Int>()

    init() throws {
        temp = try TempDirectory()
        // Left for the service to create, as it does for a new images folder.
        imageDir = temp.url.appending(path: "images", directoryHint: .isDirectory)
    }

    private func makeRequest(
        prompt: String,
        engine: EngineID = ScriptedEngine.id,
        payload: any Sendable = ScriptedEngine.Payload(),
        numberOfImages: Int = 1
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: engine, key: "model"),
            displayName: "model",
            metadataFields: [.prompt, .seed],
            payload: payload,
            prompt: prompt,
            negativePrompt: "",
            size: CGSize(width: 8, height: 8),
            startingImageData: nil,
            inputImageData: [],
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: nil,
            stepCount: 1,
            guidanceScale: nil,
            scheduler: .pndmScheduler,
            quality: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 7,
            numberOfImages: numberOfImages,
            imageDir: imageDir.path(percentEncoded: false)
        )
    }

    /// A result as a runtime hands it over: encoded bytes and metadata, with no
    /// saved location yet.
    private static func makeResult(for request: GenerationRequest) throws -> GenerationResult {
        GenerationResult(
            metadata: GenerationMetadata(
                prompt: request.prompt,
                negativePrompt: request.negativePrompt,
                width: 8,
                height: 8,
                model: request.displayName,
                engine: request.modelID.engine.rawValue,
                modelKey: request.modelID.key,
                quality: "",
                startingImage: "",
                controlNetImage: "",
                inputImages: [],
                scheduler: .pndmScheduler,
                mlComputeUnit: nil,
                seed: request.seed,
                steps: 1,
                guidanceScale: 0,
                generatedDate: Date(),
                metadataFields: request.metadataFields
            ),
            imageData: try #require(makeCGImage().pngData())
        )
    }

    /// Delivers `numberOfImages` results for every request.
    private static let deliversEveryImage:
        @Sendable (
            GenerationRequest,
            @escaping @Sendable (GenerationResult) async throws -> Void
        ) async throws -> Void = { request, onResult in
            for _ in 0..<request.numberOfImages {
                try await onResult(Self.makeResult(for: request))
            }
        }

    private func makeService(
        gallery: ImageGallery = ImageGallery(),
        body:
            @escaping @Sendable (
                GenerationRequest,
                @escaping @Sendable (GenerationResult) async throws -> Void
            ) async throws -> Void = Self.deliversEveryImage
    ) -> GenerationService {
        let runtime = ScriptedRuntime(runs: runs, body: body)
        let notifiedCounts = notifiedCounts
        return GenerationService(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(ScriptedEngine(runtime: runtime))
            ]),
            imageGallery: gallery,
            notifyImagesReady: { count in await notifiedCounts.record(count) }
        )
    }

    private func savedFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: imageDir.path(percentEncoded: false))
            .sorted()
    }

    // MARK: - Writing and emitting

    @Test("Each result is written to the images folder and emitted with its location")
    func resultsAreWrittenAndEmitted() async throws {
        let service = makeService()
        let results = await service.results()
        let request = makeRequest(prompt: "a cat", numberOfImages: 2)

        await service.enqueue(request)
        var emitted: [GenerationResult] = []
        for await result in results {
            emitted.append(result)
            if emitted.count == 2 { break }
        }
        await notifiedCounts.wait(forCount: 1)
        await Self.waitUntilIdle(service)

        // Numbered from the gallery's size, which is empty here, so one request's
        // images cannot share a name.
        let expectedNames = (1...2).map {
            imageFilenameWithoutExtension(prompt: "a cat", seed: 7, count: $0) + ".png"
        }
        #expect(emitted.map { $0.imageURL?.lastPathComponent } == expectedNames)
        #expect(try savedFiles() == expectedNames.sorted())
        for result in emitted {
            #expect(result.requestID == request.id)
            let url = try #require(result.imageURL)
            #expect(try Data(contentsOf: url) == result.imageData)
        }
        #expect(await notifiedCounts.values == [2])
    }

    @Test("Filenames continue from the number of images already in the gallery")
    func filenamesContinueFromTheGallery() async throws {
        let gallery = await MainActor.run {
            let gallery = ImageGallery()
            for _ in 0..<3 {
                gallery.add(SDImage())
            }
            return gallery
        }
        let service = makeService(gallery: gallery)
        let results = await service.results()

        await service.enqueue(makeRequest(prompt: "a cat"))
        let result = try #require(await Self.firstValue(of: results))
        await Self.waitUntilIdle(service)

        #expect(
            result.imageURL?.lastPathComponent
                == imageFilenameWithoutExtension(prompt: "a cat", seed: 7, count: 4) + ".png"
        )
    }

    // MARK: - Failed writes

    /// A result must never be dropped silently. The runtime learns that its
    /// result was not saved, and the user is told.
    @Test("A failed write fails the generation, and the queue moves on")
    func failedWriteFailsTheGeneration() async throws {
        let runtimeErrors = Recorder<GenerationError>()
        let imageDir = imageDir
        let service = makeService { request, onResult in
            if request.prompt == "unsaved" {
                // The service has created the folder by now. Removing it makes the
                // write fail.
                try FileManager.default.removeItem(at: imageDir)
                do {
                    try await onResult(Self.makeResult(for: request))
                } catch let error as GenerationError {
                    await runtimeErrors.record(error)
                    throw error
                }
                Issue.record("a result that was not saved was accepted")
            } else {
                try await onResult(Self.makeResult(for: request))
            }
        }
        let results = await service.results()
        let unsaved = makeRequest(prompt: "unsaved")
        let saved = makeRequest(prompt: "saved")

        await service.enqueue(unsaved)
        await service.enqueue(saved)
        // Results arrive in order, so the first one would be the unsaved image if
        // it had been emitted.
        let first = try #require(await Self.firstValue(of: results))
        await notifiedCounts.wait(forCount: 1)
        await Self.waitUntilIdle(service)

        #expect(first.requestID == saved.id)
        #expect(await runtimeErrors.values == [.imageDirectoryNoAccess])
        #expect(await runs.values == [unsaved.id, saved.id])
        #expect(try savedFiles() == [try #require(first.imageURL?.lastPathComponent)])
        #expect(await notifiedCounts.values.reduce(0, +) == 1)
        let outcomes = await MainActor.run { GenerationState.shared.unreportedOutcomes }
        #expect(outcomes.contains("Couldn't save image to the images folder."))
    }

    // MARK: - Rejected requests

    @Test("A request for an engine that is not registered is never queued")
    func unregisteredEngineIsRejected() async throws {
        let service = makeService()

        await service.enqueue(
            makeRequest(prompt: "a cat", engine: EngineID(rawValue: "unregistered"))
        )

        let snapshot = try #require(await Self.firstValue(of: service.updates()))
        #expect(snapshot.queue.isEmpty)
        #expect(snapshot.current == nil)
        #expect(await runs.values.isEmpty)
    }

    @Test("A request carrying another engine's payload is never queued")
    func foreignPayloadIsRejected() async throws {
        let service = makeService()

        await service.enqueue(makeRequest(prompt: "a cat", payload: ForeignPayload()))

        let snapshot = try #require(await Self.firstValue(of: service.updates()))
        #expect(snapshot.queue.isEmpty)
        #expect(snapshot.current == nil)
        #expect(await runs.values.isEmpty)
    }

    // MARK: - Gallery insertion

    @Test("The generation controller inserts each saved result into the gallery")
    @MainActor
    func controllerInsertsResults() async throws {
        let defaults = TempDefaults()
        let configStore = ConfigStore(store: defaults.defaults)
        // Keeps the controller's model scan out of the real models folders.
        configStore.modelDir = try temp.subdirectory("models").path(percentEncoded: false)
        configStore.controlNetDir = try temp.subdirectory("controlnet").path(
            percentEncoded: false)
        let gallery = ImageGallery()
        let service = makeService(gallery: gallery)
        let results = await service.results()
        let controller = GenerationController(
            configStore: configStore,
            imageGallery: gallery,
            generationService: service,
            startsObserving: true
        )
        defer { controller.shutdown() }
        let request = makeRequest(prompt: "a cat")

        await service.enqueue(request)
        let result = try #require(await Self.firstValue(of: results))
        while gallery.allImages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Self.waitUntilIdle(service)

        let inserted = try #require(gallery.allImages.only)
        #expect(inserted.id == result.id)
        #expect(inserted.path == result.imageURL?.path(percentEncoded: false))
        #expect(inserted.prompt == "a cat")
        #expect(inserted.seed == 7)
        #expect(inserted.image != nil)
        #expect(gallery.currentGeneratingImage == nil)
    }

    /// Waits until `service` has nothing running and nothing queued.
    ///
    /// Tests share the `GenerationState` singleton, so each one drains its own
    /// service before returning rather than leaving its terminal writes to land
    /// during the next test.
    private static func waitUntilIdle(_ service: GenerationService) async {
        for await snapshot in await service.updates() {
            if snapshot.current == nil, snapshot.queue.isEmpty { return }
        }
    }

    private static func firstValue<Value: Sendable>(of stream: AsyncStream<Value>) async -> Value? {
        for await value in stream {
            return value
        }
        return nil
    }
}

extension Collection {
    /// The single element, or nil when there are none or several.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
