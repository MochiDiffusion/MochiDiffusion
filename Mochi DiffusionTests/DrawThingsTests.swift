//
//  DrawThingsTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import DrawThingsClient
import Foundation
import GRPC
import NIO
import Testing

@testable import Mochi_Diffusion

private actor StubDrawThingsTransport: DrawThingsTransport {
    let catalog: Data
    var capturedPrompt: String?
    var capturedSeeds: [UInt32] = []
    var capturedSecret: String?
    var capturedPayload: DrawThingsPayload?
    private(set) var releasedPreviousImages: [Bool] = []
    private(set) weak var lastImage: CGImage?
    var shouldWait = false
    var didCancel = false
    var shouldFail = false
    var returnsNoImage = false
    private(set) var catalogRequests = 0
    var catalogError: (any Error)?
    var generationError: (any Error)?

    init(catalog: Data) {
        self.catalog = catalog
    }
    func waitForCancellation() { shouldWait = true }
    func failNextGeneration() { shouldFail = true }
    func returnNoImageOnce() { returnsNoImage = true }
    func resumeImmediately() { shouldWait = false }
    func failCatalog(with error: any Error) { catalogError = error }
    func failGenerations(with error: any Error) { generationError = error }
    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
    {
        catalogRequests += 1
        capturedSecret = sharedSecret
        if let catalogError { throw catalogError }
        return DrawThingsCatalog(models: catalog)
    }
    func generate(
        payload: DrawThingsPayload, prompt: String, seed: UInt32,
        sharedSecret: String?, session: GenerationSession
    ) async throws -> CGImage? {
        if !capturedSeeds.isEmpty {
            releasedPreviousImages.append(lastImage == nil)
        }
        capturedPrompt = prompt
        capturedSeeds.append(seed)
        capturedSecret = sharedSecret
        capturedPayload = payload
        if shouldFail {
            shouldFail = false
            throw DrawThingsError.message("Server unavailable")
        }
        if let generationError { throw generationError }
        if returnsNoImage {
            returnsNoImage = false
            return nil
        }
        if shouldWait {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                didCancel = true
                throw error
            }
        }
        let image = makeCGImage(width: 16, height: 16)
        lastImage = image
        return image
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DrawThingsTests {
    private var connection: DrawThingsConnection {
        DrawThingsConnection(enabled: true, host: "localhost", port: 7859, useTLS: false)
    }
    private var catalog: Data {
        Data(
            #"""
            [
              {"file":"flux_2_klein_4b_q8p.ckpt","name":"Klein","version":"flux2_4b","modifier":"kontext","default_scale":16,"future_field":{"x":42}},
              {"file":"sd_v1.5_f16.ckpt","name":"SD 1.5","version":"v1","default_scale":8},
              {"file":"flux_2_klein_4b_q8p.ckpt","name":"duplicate","version":"flux2_4b"},
              {"file":"video.ckpt","version":"wan_v2.1_14b"},
              {"file":"qwen_image_edit_2511_q6p.ckpt","version":"qwen_image","modifier":"qwenimage_edit_plus"},
              {"file":"broken.ckpt"},
              "malformed entry"
            ]
            """#.utf8)
    }
    private func model() throws -> DrawThingsModel {
        try #require(
            DrawThingsEngine.models(from: catalog, connection: connection).first
        )
    }

    @Test(
        "Image dimensions resolve identically in the plan and wire configuration",
        arguments: [
            CGSize(width: 1024, height: 768), CGSize(width: 777, height: 333),
            CGSize(width: 1, height: 9000),
        ])
    func sizes(size: CGSize) throws {
        var input = draft()
        input.configuredSize = size
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: input, model: model())
        #expect(
            CGSize(
                width: Int(plan.payload.configuration.width),
                height: Int(plan.payload.configuration.height)) == plan.size)
        #expect((64...2048).contains(Int(plan.size.width)))
        #expect((64...2048).contains(Int(plan.size.height)))
        #expect(Int(plan.size.width) % 64 == 0)
        #expect(Int(plan.size.height) % 64 == 0)
    }

    private actor Notifications {
        var counts: [Int] = []
        func record(_ count: Int) { counts.append(count) }
    }

    @Test(
        "Failed, empty and cancelled generations return the button to Generate without a success notification",
        arguments: ["failure", "empty", "cancellation"])
    @MainActor func recovery(outcome: String) async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        if outcome == "failure" { await transport.failNextGeneration() }
        if outcome == "empty" { await transport.returnNoImageOnce() }
        if outcome == "cancellation" { await transport.waitForCancellation() }
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(DrawThingsEngine(secrets: NoSecretStore(), transport: transport))
        ])
        let gallery = ImageGallery()
        let notifications = Notifications()
        let service = GenerationService(
            engineRegistry: registry, imageGallery: gallery,
            notifyImagesReady: { await notifications.record($0) })
        let defaults = TempDefaults()
        let directory = try TempDirectory()
        let config = ConfigStore(store: defaults.defaults)
        config.modelDir = directory.url.path
        config.controlNetDir = directory.url.path
        let controller = GenerationController(
            configStore: config, imageGallery: gallery, generationService: service,
            engineRegistry: registry)
        defer { controller.shutdown() }
        let first = try request(imageDir: directory.url.path)
        await service.enqueue(first)
        while await transport.capturedPrompt == nil { await Task.yield() }
        if outcome == "cancellation" {
            while !controller.hasGenerationWork { await Task.yield() }
            #expect(controller.hasGenerationWork)
            await service.stopCurrentGeneration()
            await transport.resumeImmediately()
        }
        await QueueLivenessTests().waitUntilIdle(service)
        while controller.hasGenerationWork { await Task.yield() }
        #expect(!controller.hasGenerationWork)
        let second = try request(imageDir: directory.url.path)
        await service.enqueue(second)
        while !(await notifications.counts.contains(1)) { await Task.yield() }
        await QueueLivenessTests().waitUntilIdle(service)
        #expect(await notifications.counts == [1])
    }
    private func draft() -> GenerationDraft {
        GenerationDraft(
            prompt: "a cat", negativePrompt: "blurry",
            configuredSize: CGSize(width: 777, height: 333),
            inputImages: [], controlNets: [], strength: 0.5, stepCount: 99, guidanceScale: 11,
            scheduler: .pndmScheduler, seed: 7, numberOfImages: 8,
            computeUnitPreference: .auto, reduceMemory: false, safetyChecker: false,
            showGenerationPreview: false, imageDir: "/tmp",
            controlNetDirectory: URL(fileURLWithPath: "/nonexistent")
        )
    }
    private func request(
        model selectedModel: DrawThingsModel? = nil,
        imageDir: String = "/tmp", numberOfImages: Int = 1
    ) throws
        -> GenerationRequest
    {
        let model = try selectedModel ?? model()
        var input = draft()
        input.numberOfImages = numberOfImages
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: input, model: model)
        return GenerationRequest(
            modelID: model.id, displayName: model.name, metadataFields: model.metadataFields,
            payload: plan.payload, prompt: "a cat", negativePrompt: "", size: plan.size,
            startingImageData: nil, inputImageData: [], startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [], inputImageNames: [], strength: nil, stepCount: plan.stepCount,
            guidanceScale: plan.guidanceScale, scheduler: nil, mlComputeUnit: nil,
            useDenoisedIntermediates: false, seed: 7, numberOfImages: plan.numberOfImages,
            imageDir: imageDir
        )
    }

    @Test(
        "Discovery tolerates newer fields and malformed entries, excludes video/editing, and deduplicates"
    )
    func discovery() throws {
        let models = try DrawThingsEngine.models(from: catalog, connection: connection)
        #expect(models.map(\.name) == ["Klein", "SD 1.5"])
        let model = try #require(models.first)
        let echoed = try #require(
            JSONSerialization.jsonObject(with: model.specification) as? [[String: Any]])
        #expect((echoed.first?["future_field"] as? [String: Int])?["x"] == 42)
        #expect(model.configuration.model == "flux_2_klein_4b_q8p.ckpt")
        #expect(model.configuration.steps == 4)
        #expect(model.configuration.guidanceScale == 1)
        #expect(model.configuration.width == 1024)
        #expect(models[1].configuration.steps == 16)
        #expect(models[1].configuration.width == 512)
    }

    @Test("A disabled engine performs no network discovery")
    func disabled() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let engine = DrawThingsEngine(secrets: NoSecretStore(), transport: transport)
        let settings = EngineSettings(
            modelDirectory: URL(fileURLWithPath: "/missing"),
            controlNetDirectory: URL(fileURLWithPath: "/missing"))
        #expect(try await engine.discoverModels(ModelDiscoveryContext(settings: settings)).isEmpty)
        #expect(await engine.availability(settings) != .ready)
    }

    @Test("Missing local folders cannot prevent Draw Things discovery")
    func remoteDiscovery() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let secrets = InMemorySecretStore([DrawThingsConnection.secretAccount: "secret"])
        let engine = DrawThingsEngine(secrets: secrets, transport: transport)
        let settings = EngineSettings(
            modelDirectory: URL(fileURLWithPath: "/missing"),
            controlNetDirectory: URL(fileURLWithPath: "/missing"),
            drawThings: connection
        )
        let models = try await engine.discoverModels(ModelDiscoveryContext(settings: settings))
        #expect(models.count == 2)
        #expect(await transport.capturedSecret == "secret")
    }

    @Test(
        "Empty catalog explains the server setup requirement", arguments: [Data(), Data("[]".utf8)])
    func emptyCatalog(data: Data) {
        #expect(throws: DrawThingsError.self) {
            try DrawThingsEngine.models(from: data, connection: connection)
        }
    }

    @Test("Planning applies the sidebar's values and retains the endpoint and specification")
    func planning() throws {
        let model = try model()
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: draft(), model: model)
        #expect(plan.size == CGSize(width: 768, height: 320))
        #expect(plan.payload.configuration.width == 768)
        #expect(plan.payload.configuration.height == 320)
        #expect(plan.payload.configuration.originalImageWidth == 768)
        #expect(plan.payload.configuration.targetImageHeight == 320)
        #expect(plan.numberOfImages == 8)
        #expect(plan.stepCount == 99)
        #expect(plan.payload.configuration.steps == 99)
        #expect(plan.guidanceScale == 11)
        #expect(plan.payload.configuration.guidanceScale == 11)
        #expect(plan.payload.negativePrompt == "blurry")
        #expect(plan.payload.architecture == "FLUX.2 Klein 4B")
        #expect(plan.payload.connection == connection)
        #expect(plan.payload.specification == model.specification)
        #expect(plan.scheduler == nil)
        #expect(!model.metadataFields.contains(.scheduler))
        #expect(plan.inputImageData.isEmpty)
    }

    @Test("Which options a model offers comes from its catalog flags")
    func optionsFromCatalogFlags() throws {
        let catalog = Data(
            #"""
            [
              {"file":"z_image_turbo_1.0_q6p.ckpt","name":"Z-Image Turbo","version":"z_image"},
              {"file":"flux_1_dev_q5p.ckpt","name":"FLUX.1 dev","version":"flux1","guidance_embed":true},
              {"file":"flux_1_schnell_q5p.ckpt","name":"FLUX.1 schnell","version":"flux1","is_consistency_model":true},
              {"file":"ideogram_4_q8p.ckpt","name":"Ideogram 4","version":"ideogram_4"},
              {"file":"future.ckpt","name":"Future","version":"some_future_family"}
            ]
            """#.utf8)
        let models = try DrawThingsEngine.models(from: catalog, connection: connection)
        #expect(
            models.map(\.name) == ["Z-Image Turbo", "FLUX.1 dev", "FLUX.1 schnell", "Ideogram 4"])

        let plain = models[0].constraints
        #expect(plain.supportsNegativePrompt)
        #expect(plain.guidanceScale.isSupported)
        #expect(models[0].metadataFields.isSuperset(of: [.negativePrompt, .guidanceScale]))

        let embedded = models[1].constraints
        #expect(!embedded.supportsNegativePrompt)
        #expect(embedded.guidanceScale.isSupported)
        #expect(!models[1].metadataFields.contains(.negativePrompt))

        #expect(models[0].recommendedGuidanceScale != nil)
        #expect(models[2].recommendedGuidanceScale == nil)
        #expect(models[2].recommendedSteps == Int(models[2].configuration.steps))

        let consistency = models[2].constraints
        #expect(!consistency.supportsNegativePrompt)
        #expect(!consistency.guidanceScale.isSupported)
        #expect(models[2].metadataFields.isDisjoint(with: [.negativePrompt, .guidanceScale]))

        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(
            draft: draft(), model: models[2])
        #expect(plan.payload.negativePrompt.isEmpty)
        #expect(plan.guidanceScale == nil)
        #expect(plan.payload.configuration.guidanceScale == models[2].configuration.guidanceScale)
    }

    /// How a model applies guidance, from its catalog flags.
    enum GuidanceKind: CaseIterable {
        case cfg, embedded, consistency
    }

    @Test(
        "Guidance recommendations, wire values and PNG metadata use the model's active guidance",
        arguments: GuidanceKind.allCases)
    @MainActor func guidanceResolution(kind: GuidanceKind) async throws {
        var configuration = DrawThingsConfiguration(model: "guidance.ckpt")
        configuration.guidanceScale = 2
        configuration.guidanceEmbed = 4.5
        configuration.speedUpWithGuidanceEmbed = false
        let model = DrawThingsModel(
            file: "guidance.ckpt", name: "Guidance test", version: "flux1",
            isConsistencyModel: kind == .consistency,
            usesGuidanceEmbedding: kind == .embedded, connection: connection,
            specification: Data(), configuration: configuration)
        let transport = StubDrawThingsTransport(catalog: Data())
        let runtime = DrawThingsRuntime(secrets: NoSecretStore(), transport: transport)
        let request = try request(model: model)
        let results = ResultCollector()
        try await runtime.run(request: request, session: GenerationSession(requestID: request.id)) {
            await results.add($0)
        }
        let sent = try #require(await transport.capturedPayload).configuration
        switch kind {
        case .embedded:
            #expect(model.recommendedGuidanceScale == 4.5)
            #expect(sent.speedUpWithGuidanceEmbed)
            #expect(sent.guidanceEmbed == 11)
            #expect(sent.guidanceScale == 2)
        case .cfg:
            #expect(model.recommendedGuidanceScale == 2)
            #expect(sent.guidanceScale == 11)
            #expect(sent.guidanceEmbed == 4.5)
        case .consistency:
            #expect(model.recommendedGuidanceScale == nil)
            #expect(sent.guidanceScale == 2)
            #expect(sent.guidanceEmbed == 4.5)
        }
        let expectedGuidance: Double? = kind == .consistency ? nil : 11
        #expect(request.guidanceScale.map(Double.init) == expectedGuidance)
        let result = try #require(await results.all.first)
        #expect(result.metadata.guidanceScale == expectedGuidance)
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("guidance.png")
        try result.imageData.write(to: url)
        let record = try #require(createImageRecordFromURL(url))
        #expect(record.metadataFields.contains(.guidanceScale) == (expectedGuidance != nil))
        if let expectedGuidance {
            #expect(record.guidanceScale == expectedGuidance)
        }
    }

    @Test("A batch releases completed images before generating the next image")
    func batchImageLifetime() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let runtime = DrawThingsRuntime(secrets: NoSecretStore(), transport: transport)
        let request = try request(numberOfImages: 3)
        let session = GenerationSession(requestID: request.id)
        defer { session.close() }
        try await runtime.run(request: request, session: session) { _ in }
        #expect(await transport.releasedPreviousImages == [true, true])
        // The session is still open and retains its cancellation handler here.
        #expect(await transport.lastImage == nil)
    }

    @Test("Cancelling after a batch result interrupts the next image and skips the remainder")
    func cancellationDuringBatch() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let runtime = DrawThingsRuntime(secrets: NoSecretStore(), transport: transport)
        let request = try request(numberOfImages: 3)
        let session = GenerationSession(requestID: request.id)
        defer { session.close() }
        let results = ResultCollector()
        let work = Task {
            try await runtime.run(request: request, session: session) {
                await results.add($0)
                await transport.waitForCancellation()
            }
        }
        while await transport.capturedSeeds.count < 2 { await Task.yield() }
        session.cancel()
        try await work.value
        #expect(await transport.didCancel)
        #expect(await transport.capturedSeeds == [7, 8])
        #expect(await results.all.count == 1)
    }

    @Test("Only a complete final image can succeed")
    func chunks() throws {
        var accumulator = DrawThingsImageAccumulator()
        #expect(throws: DrawThingsError.self) { try accumulator.finishedImage() }
        try accumulator.append([Data([1, 2])], isLastChunk: false)
        #expect(throws: DrawThingsError.self) { try accumulator.finishedImage() }
        try accumulator.append([Data([3, 4])], isLastChunk: true)
        #expect(try accumulator.finishedImage() == Data([1, 2, 3, 4]))
        #expect(throws: DrawThingsError.self) {
            try accumulator.append([Data([5])], isLastChunk: true)
        }
    }

    @Test("Endpoint validation rejects URLs and invalid ports")
    func connectionValidation() throws {
        var value = connection
        value.host = "  studio.local  "
        #expect(try value.validated().host == "studio.local")
        value.host = "https://studio.local"
        #expect(throws: DrawThingsError.self) { try value.validated() }
        value.host = "studio.local"
        value.port = 0
        #expect(throws: DrawThingsError.self) { try value.validated() }
    }

    @Test("Settings persist without a secret, and start switched off with no host")
    @MainActor func persistence() throws {
        let suite = "DrawThingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EngineSettingsStore(store: defaults)
        #expect(store.drawThings == DrawThingsConnection(enabled: false, host: "", port: 7859))
        store.drawThings = connection
        let restored = EngineSettingsStore(store: defaults)
        #expect(restored.drawThings == connection)
    }

    @Test("Switched on with no host, Draw Things makes no network call")
    func noHost() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let engine = DrawThingsEngine(secrets: NoSecretStore(), transport: transport)
        var empty = connection
        empty.host = ""
        let settings = EngineSettings(
            modelDirectory: URL(fileURLWithPath: "/missing"),
            controlNetDirectory: URL(fileURLWithPath: "/missing"), drawThings: empty)
        #expect(try await engine.discoverModels(ModelDiscoveryContext(settings: settings)).isEmpty)
        #expect(await engine.availability(settings) != .ready)
        #expect(await transport.catalogRequests == 0)
    }

    @Test("Host and port fields keep only the characters they can use")
    func fieldFilters() {
        #expect(DrawThingsConnection.filteredHost("studio.local") == "studio.local")
        #expect(DrawThingsConnection.filteredHost("192.168.1.5") == "192.168.1.5")
        #expect(DrawThingsConnection.filteredHost("my-mac.local") == "my-mac.local")
        #expect(DrawThingsConnection.filteredHost(" http://stüdio_1:80/ ") == "httpstdio180")
        #expect(DrawThingsConnection.filteredPort("78a59") == "7859")
        #expect(DrawThingsConnection.filteredPort("1234567") == "12345")
    }

    /// Builds a controller whose only engine is Draw Things, with no local models.
    @MainActor private func statusController(
        transport: StubDrawThingsTransport, connection: DrawThingsConnection
    ) throws -> (GenerationController, TempDirectory, TempDefaults) {
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(DrawThingsEngine(secrets: NoSecretStore(), transport: transport))
        ])
        let defaults = TempDefaults()
        let directory = try TempDirectory()
        let config = ConfigStore(store: defaults.defaults)
        config.modelDir = directory.url.path
        let settings = EngineSettingsStore(store: defaults.defaults)
        settings.drawThings = connection
        let controller = makeTestGenerationController(
            configStore: config, engineRegistry: registry, engineSettings: settings,
            startsObserving: false)
        return (controller, directory, defaults)
    }

    @Test("Settings shows the result of the last model-list fetch, with the server's reason")
    @MainActor func statusFromFetch() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let (controller, _, _) = try statusController(transport: transport, connection: connection)
        #expect(controller.drawThingsStatus == .inactive)
        await controller.loadModels(from: [.connection])
        #expect(controller.drawThingsStatus == .connected(warning: nil))

        let refusal = "Draw Things requires a shared secret."
        await transport.failCatalog(with: DrawThingsError.message(refusal))
        await controller.loadModels(from: [.connection])
        #expect(controller.drawThingsStatus == .notConnected(refusal))
        #expect(!controller.hasModels(.drawThings))
        // Settings reports the server; the main window does not blame a models folder.
        #expect(controller.discoveryMessage?.contains("Couldn't read the models folder") != true)

        // A server with nothing Mochi can use answered, so it is a warning.
        let empty = "Draw Things returned an unreadable model list."
        await transport.failCatalog(with: DrawThingsError.unusableModelList(empty))
        await controller.loadModels(from: [.connection])
        #expect(controller.drawThingsStatus == .connected(warning: empty))

        await transport.failCatalog(with: GRPCStatus(code: .unavailable, message: nil))
        await controller.loadModels(from: [.connection])
        guard case .notConnected(let reason) = controller.drawThingsStatus else {
            Issue.record("Expected Not connected, got \(controller.drawThingsStatus)")
            return
        }
        #expect(reason.contains("didn't answer"))

        controller.engineSettings.drawThings.enabled = false
        await controller.loadModels(from: [.connection])
        #expect(controller.drawThingsStatus == .inactive)
        #expect(await transport.catalogRequests == 4)
    }

    @Test("Generations report whether they reached the server")
    func generationContacts() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let (contacts, continuation) = AsyncStream.makeStream(of: DrawThingsContact.self)
        let runtime = DrawThingsRuntime(
            secrets: NoSecretStore(), transport: transport, contacts: continuation)
        let request = try request()
        let run = { () async -> Void in
            try? await runtime.run(
                request: request, session: GenerationSession(requestID: request.id)
            ) { _ in }
        }
        await run()
        // Draw Things answering with its own error still means it was reached.
        await transport.failGenerations(with: DrawThingsError.message("Out of memory"))
        await run()
        await transport.failGenerations(with: GRPCStatus(code: .unavailable, message: nil))
        await run()
        await transport.failGenerations(
            with: GRPCStatus(code: .deadlineExceeded, message: nil))
        await run()
        // A stop says nothing about the server.
        await transport.failGenerations(with: CancellationError())
        await run()
        continuation.finish()

        var reports: [DrawThingsContact] = []
        for await contact in contacts { reports.append(contact) }
        #expect(reports.map { $0.failure == nil } == [true, true, false, false])
        #expect(reports.allSatisfy { $0.connection == connection })
    }

    @Test("A generation's contact updates Settings only for the server it names")
    @MainActor func statusFromGeneration() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let (controller, _, _) = try statusController(transport: transport, connection: connection)
        await controller.loadModels(from: [.connection])

        controller.apply(DrawThingsContact(connection: connection, failure: "No answer"))
        #expect(controller.drawThingsStatus == .notConnected("No answer"))
        // A failed generation leaves the model list and selection alone.
        #expect(controller.hasModels(.drawThings))
        #expect(controller.currentModelId?.engine == .drawThings)

        controller.apply(DrawThingsContact(connection: connection, failure: nil))
        #expect(controller.drawThingsStatus == .connected(warning: nil))

        var other = connection
        other.host = "studio.local"
        controller.apply(DrawThingsContact(connection: other, failure: "No answer"))
        #expect(controller.drawThingsStatus == .connected(warning: nil))
    }

    @Test(
        "Runtime forwards the prompt/seed/credential and encodes a gallery image with honest metadata"
    )
    @MainActor func runtime() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let runtime = DrawThingsRuntime(
            secrets: InMemorySecretStore([DrawThingsConnection.secretAccount: "secret"]),
            transport: transport
        )
        let request = try request(numberOfImages: 3)
        let results = ResultCollector()
        try await runtime.run(request: request, session: GenerationSession(requestID: request.id)) {
            await results.add($0)
        }
        #expect(await transport.capturedPrompt == "a cat")
        #expect(await transport.capturedSeeds == [7, 8, 9])
        #expect(await transport.capturedPayload?.negativePrompt == "blurry")
        #expect(await transport.capturedSecret == "secret")
        #expect(await results.all.map(\.metadata.seed) == [7, 8, 9])
        let result = try #require(await results.all.first)
        #expect(pixelSize(of: result.imageData) == CGSize(width: 16, height: 16))
        #expect(result.metadata.engine == "drawthings")
        #expect(result.metadata.steps == 99)
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("drawthings.png")
        try result.imageData.write(to: url)
        let record = try #require(createImageRecordFromURL(url))
        #expect(record.engine == "drawthings")
        #expect(record.modelKey == "flux_2_klein_4b_q8p.ckpt")
        #expect(record.seed == 7)
        #expect(record.steps == 99)
        #expect(record.guidanceScale == 11)
        #expect(record.negativePrompt == "blurry")
        // The recommended configuration's sampler for Klein 4B, under its own name.
        #expect(result.metadata.samplerName == "DDIM Trailing")
        #expect(record.details.contains(MetadataDetail(label: "Sampler", value: "DDIM Trailing")))
        #expect(!record.metadataFields.contains(.scheduler))
    }

    @Test("Cancelling a session cancels suspended transport work without publishing a result")
    func cancellation() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        await transport.waitForCancellation()
        let runtime = DrawThingsRuntime(secrets: NoSecretStore(), transport: transport)
        let request = try request()
        let session = GenerationSession(requestID: request.id)
        let results = ResultCollector()
        let work = Task {
            try await runtime.run(request: request, session: session) { await results.add($0) }
        }
        while await transport.capturedPrompt == nil { await Task.yield() }
        session.cancel()
        try await work.value
        #expect(await transport.didCancel)
        #expect(await results.all.isEmpty)
    }
}

// Exercise the actual HTTP/2 + protobuf transport without requiring model weights.
// This server returns a synthetic tensor; it is not evidence of real inference.
private final class DrawThingsLoopbackService: CallHandlerProvider, Sendable {
    let serviceName: Substring = "ImageGenerationService"
    let catalog: Data
    let tensor: Data
    let expectedConfiguration: Data

    init(catalog: Data, tensor: Data, expectedConfiguration: Data) {
        self.catalog = catalog
        self.tensor = tensor
        self.expectedConfiguration = expectedConfiguration
    }

    func handle(method name: Substring, context: CallHandlerContext) -> (
        any GRPCServerHandlerProtocol
    )? {
        switch name {
        case "Echo":
            return UnaryServerHandler(
                context: context,
                requestDeserializer: ProtobufDeserializer<EchoRequest>(),
                responseSerializer: ProtobufSerializer<EchoReply>(),
                interceptors: []
            ) { request, context in
                var reply = EchoReply()
                reply.sharedSecretMissing = request.sharedSecret != "test-secret"
                if !reply.sharedSecretMissing {
                    reply.override.models = self.catalog
                }
                return context.eventLoop.makeSucceededFuture(reply)
            }
        case "GenerateImage":
            return ServerStreamingServerHandler(
                context: context,
                requestDeserializer: ProtobufDeserializer<ImageGenerationRequest>(),
                responseSerializer: ProtobufSerializer<ImageGenerationResponse>(),
                interceptors: []
            ) { request, context in
                #expect(request.prompt == "transport test")
                #expect(request.negativePrompt == "blurry")
                #expect(request.sharedSecret == "test-secret")
                #expect(request.configuration == self.expectedConfiguration)
                #expect(request.override.models == self.catalog)
                #expect(request.chunked)
                var first = ImageGenerationResponse()
                first.chunkState = .moreChunks
                first.generatedImages = [self.tensor.prefix(self.tensor.count / 2)]
                var last = ImageGenerationResponse()
                last.chunkState = .lastChunk
                last.generatedImages = [
                    self.tensor.suffix(self.tensor.count - self.tensor.count / 2)
                ]
                return context.sendResponses([first, last]).map { GRPCStatus.ok }
            }
        default:
            return nil
        }
    }
}

struct DrawThingsGRPCTests {
    @Test(
        "Real gRPC Echo auth, request serialization, chunk assembly and tensor decode work over loopback"
    )
    func roundTrip() async throws {
        let catalog = Data(
            #"[{"file":"sd_v1.5_f16.ckpt","name":"SD","version":"v1","default_scale":8}]"#.utf8)
        var connection = DrawThingsConnection(
            enabled: true, host: "127.0.0.1", port: 7859, useTLS: false)
        let model = try #require(
            DrawThingsEngine.models(from: catalog, connection: connection).first)
        var configuration = model.configuration
        configuration.seed = 123
        configuration.width = 768
        configuration.height = 512
        let tensor = try ImageHelpers.imageToDTTensor(makeCGImage(width: 16, height: 16))
        let service = DrawThingsLoopbackService(
            catalog: model.specification, tensor: tensor,
            expectedConfiguration: try configuration.toFlatBufferData()
        )
        let server = try await Server.insecure(group: MultiThreadedEventLoopGroup.singleton)
            .withServiceProviders([service]).bind(host: "127.0.0.1", port: 0).get()
        do {
            connection.port = try #require(server.channel.localAddress?.port)
            let transport = GRPCDrawThingsTransport()
            await #expect(throws: DrawThingsError.self) {
                try await transport.catalog(connection: connection, sharedSecret: nil)
            }
            let discovered = try await transport.catalog(
                connection: connection, sharedSecret: "test-secret")
            #expect(discovered.models == model.specification)
            let image = try await transport.generate(
                payload: DrawThingsPayload(
                    connection: connection, specification: discovered.models,
                    configuration: configuration, negativePrompt: "blurry",
                    architecture: nil),
                prompt: "transport test", seed: 123, sharedSecret: "test-secret",
                session: GenerationSession(requestID: UUID())
            )
            #expect(image?.width == 16)
            #expect(image?.height == 16)
            try await server.close().get()
        } catch {
            try? await server.close().get()
            throw error
        }
    }
}
