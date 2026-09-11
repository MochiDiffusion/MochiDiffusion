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
    let loras: Data
    var capturedPrompt: String?
    var capturedSeed: UInt32?
    var capturedSecret: String?
    var capturedPayload: DrawThingsPayload?
    var shouldWait = false
    var didCancel = false
    var shouldFail = false
    var returnsNoImage = false

    init(catalog: Data, loras: Data = Data()) {
        self.catalog = catalog
        self.loras = loras
    }
    func waitForCancellation() { shouldWait = true }
    func failNextGeneration() { shouldFail = true }
    func returnNoImageOnce() { returnsNoImage = true }
    func resumeImmediately() { shouldWait = false }
    func catalog(connection: DrawThingsConnection, sharedSecret: String?) async throws
        -> DrawThingsCatalog
    {
        capturedSecret = sharedSecret
        return DrawThingsCatalog(models: catalog, loras: loras)
    }
    func generate(
        payload: DrawThingsPayload, prompt: String, seed: UInt32,
        sharedSecret: String?, session: GenerationSession
    ) async throws -> CGImage? {
        capturedPrompt = prompt
        capturedSeed = seed
        capturedSecret = sharedSecret
        capturedPayload = payload
        if shouldFail {
            shouldFail = false
            throw DrawThingsError.message("Server unavailable")
        }
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
        return makeCGImage(width: 16, height: 16)
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
            DrawThingsEngine.models(from: catalog, connection: connection, loras: loraCatalog).first
        )
    }

    private var loraCatalog: Data {
        Data(
            #"""
            [
              {"file":"style.ckpt","name":"Style","version":"flux2_4b","prefix":"painted","future_field":42,"weight":{"value":0.8,"lower_bound":-1,"upper_bound":2}},
              {"file":"style.ckpt","name":"Duplicate","version":"flux2_4b"},
              {"file":"sd_style.ckpt","version":"v1"},
              {"file":"lcm.ckpt","version":"flux2_4b","is_consistency_model":true},
              {"file":"inpaint.ckpt","version":"flux2_4b","modifier":"inpainting"},
              {"file":"transparent.ckpt","version":"flux2_4b","alternative_decoder":"vae.ckpt"},
              {"file":"bad_range.ckpt","version":"flux2_4b","weight":{"lower_bound":2,"upper_bound":1}},
              {"name":"Missing filename"}
            ]
            """#.utf8)
    }

    @Test("LoRA discovery filters compatibility and preserves server metadata and weight limits")
    func loraDiscoveryAndPlanning() throws {
        let models = try DrawThingsEngine.models(
            from: catalog, connection: connection, loras: loraCatalog)
        #expect(models[0].loras.map(\.file) == ["style.ckpt"])
        #expect(models[1].loras.map(\.file) == ["sd_style.ckpt"])
        #expect(models[0].loras[0].defaultWeight == 0.8)
        #expect(models[0].loras[0].trigger == "painted")
        var input = draft()
        input.loras = [LoRASelection(file: "style.ckpt", weight: -0.5)]
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(
            draft: input, model: models[0])
        #expect(plan.payload.configuration.loras.first?.file == "style.ckpt")
        #expect(plan.payload.configuration.loras.first?.weight == -0.5)
        let specifications = try #require(
            JSONSerialization.jsonObject(with: plan.payload.loraSpecifications) as? [[String: Any]])
        #expect(specifications.count == 1)
        #expect(specifications[0]["future_field"] as? Int == 42)
        input.loras = []
        #expect(plan.payload.configuration.loras.count == 1)
    }

    @Test(
        "Planning refuses unavailable LoRAs, duplicate selections and invalid weights",
        arguments: [
            [LoRASelection(file: "sd_style.ckpt", weight: 1)],
            [LoRASelection(file: "style.ckpt", weight: .nan)],
            [LoRASelection(file: "style.ckpt", weight: 3)],
            [
                LoRASelection(file: "style.ckpt", weight: 1),
                LoRASelection(file: "style.ckpt", weight: 0.5),
            ],
        ])
    func invalidLoRAs(selections: [LoRASelection]) throws {
        let model = try #require(
            DrawThingsEngine.models(from: catalog, connection: connection, loras: loraCatalog).first
        )
        var input = draft()
        input.loras = selections
        #expect(throws: DrawThingsError.self) {
            try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: input, model: model)
        }
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

    @Test("Sidebar LoRAs are captured in a request and clear when the model or server changes")
    @MainActor func sidebarSelections() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog, loras: loraCatalog)
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(DrawThingsEngine(secrets: NoSecretStore(), transport: transport))
        ])
        let defaults = TempDefaults()
        let settings = EngineSettingsStore(store: defaults.defaults, engines: [.drawThings])
        settings.drawThings = connection
        settings.selectedEngine = .drawThings
        let controller = makeTestGenerationController(
            configStore: ConfigStore(store: defaults.defaults), engineRegistry: registry,
            engineSettings: settings, startsObserving: false
        )
        defer { controller.shutdown() }
        await controller.loadModels()
        let models = controller.visibleModels
        #expect(models.count == 2)
        controller.currentModelId = models[0].id
        controller.drawThingsLoRAs = [LoRASelection(file: "style.ckpt", weight: 0.75)]
        let request = try #require(controller.buildGenerationRequest())
        let payload = try #require(request.payload as? DrawThingsPayload)
        #expect(payload.configuration.loras.first?.weight == 0.75)
        await controller.loadModels()
        #expect(controller.drawThingsLoRAs.count == 1)
        controller.currentModelId = models[1].id
        #expect(controller.drawThingsLoRAs.isEmpty)
        #expect(payload.configuration.loras.first?.file == "style.ckpt")
        controller.currentModelId = models[0].id
        controller.drawThingsLoRAs = [LoRASelection(file: "style.ckpt", weight: 0.75)]
        var remote = connection
        remote.host = "studio.local"
        settings.drawThings = remote
        await controller.loadModels()
        #expect(controller.drawThingsLoRAs.isEmpty)
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
            scheduler: .pndmScheduler, quality: .high, seed: 7, numberOfImages: 8,
            computeUnitPreference: .auto, reduceMemory: false, safetyChecker: false,
            showGenerationPreview: false, imageDir: "/tmp", imageType: "png",
            controlNetDirectory: URL(fileURLWithPath: "/nonexistent")
        )
    }
    private func request(imageDir: String = "/tmp", loras: [LoRASelection] = []) throws
        -> GenerationRequest
    {
        let model = try model()
        var input = draft()
        input.loras = loras
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: input, model: model)
        return GenerationRequest(
            modelID: model.id, displayName: model.name, metadataFields: model.metadataFields,
            payload: plan.payload, prompt: "a cat", negativePrompt: "", size: plan.size,
            startingImageData: nil, inputImageData: [], startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [], inputImageNames: [], strength: nil, stepCount: plan.stepCount,
            guidanceScale: plan.guidanceScale, scheduler: nil, quality: nil, mlComputeUnit: nil,
            useDenoisedIntermediates: false, seed: 7, numberOfImages: 1, imageDir: imageDir,
            imageType: "png"
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
        let secrets = InMemorySecretStore([connection.secretAccount: "secret"])
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

    @Test("Planning pins defaults and retains the discovered endpoint and complete specification")
    func planning() throws {
        let model = try model()
        let plan = try DrawThingsEngine(secrets: NoSecretStore()).plan(draft: draft(), model: model)
        #expect(plan.size == CGSize(width: 768, height: 320))
        #expect(plan.payload.configuration.width == 768)
        #expect(plan.payload.configuration.height == 320)
        #expect(plan.numberOfImages == 1)
        #expect(plan.stepCount == 4)
        #expect(plan.guidanceScale == 1)
        #expect(plan.payload.connection == connection)
        #expect(plan.payload.specification == model.specification)
        #expect(plan.scheduler == nil)
        #expect(!model.metadataFields.contains(.scheduler))
        #expect(plan.inputImageData.isEmpty)
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

    @Test("Settings persist without a secret and credentials are scoped to the endpoint")
    @MainActor func persistence() throws {
        let suite = "DrawThingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EngineSettingsStore(store: defaults, engines: [.drawThings])
        store.drawThings = connection
        let restored = EngineSettingsStore(store: defaults, engines: [.drawThings])
        #expect(restored.drawThings == connection)
        var remote = connection
        remote.host = "studio.local"
        #expect(remote.secretAccount != connection.secretAccount)
    }

    @Test(
        "Runtime forwards the prompt/seed/credential and encodes a gallery image with honest metadata"
    )
    @MainActor func runtime() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        let runtime = DrawThingsRuntime(
            secrets: InMemorySecretStore([connection.secretAccount: "secret"]), transport: transport
        )
        let selections = [LoRASelection(file: "style.ckpt", weight: 0.75)]
        let request = try request(loras: selections)
        let results = OpenAIRuntimeTests.ResultCollector()
        try await runtime.run(request: request, session: GenerationSession(requestID: request.id)) {
            await results.add($0)
        }
        #expect(await transport.capturedPrompt == "a cat")
        #expect(await transport.capturedSeed == 7)
        #expect(await transport.capturedSecret == "secret")
        let result = try #require(await results.all.first)
        #expect(pixelSize(of: result.imageData) == CGSize(width: 16, height: 16))
        #expect(result.metadata.engine == "drawthings")
        #expect(result.metadata.steps == 4)
        #expect(result.metadata.loras == selections)
        let directory = try TempDirectory()
        let url = directory.url.appendingPathComponent("lora.png")
        try result.imageData.write(to: url)
        let record = try #require(createImageRecordFromURL(url))
        #expect(record.loras == selections)
        #expect(record.metadataFields.contains(.loras))
        #expect(!result.metadata.metadataFields.contains(.scheduler))
    }

    @Test("Cancelling a session cancels suspended transport work without publishing a result")
    func cancellation() async throws {
        let transport = StubDrawThingsTransport(catalog: catalog)
        await transport.waitForCancellation()
        let runtime = DrawThingsRuntime(secrets: NoSecretStore(), transport: transport)
        let request = try request()
        let session = GenerationSession(requestID: request.id)
        let results = OpenAIRuntimeTests.ResultCollector()
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
    let loras: Data

    init(catalog: Data, tensor: Data, expectedConfiguration: Data, loras: Data) {
        self.catalog = catalog
        self.tensor = tensor
        self.expectedConfiguration = expectedConfiguration
        self.loras = loras
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
                    reply.override.loras = self.loras
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
                #expect(request.sharedSecret == "test-secret")
                #expect(request.configuration == self.expectedConfiguration)
                #expect(request.override.models == self.catalog)
                #expect(request.override.loras == self.loras)
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
        configuration.loras = [LoRAConfig(file: "style.ckpt", weight: 0.75)]
        let loras = Data(#"[{"file":"style.ckpt","version":"v1","future_field":42}]"#.utf8)
        let tensor = try ImageHelpers.imageToDTTensor(makeCGImage(width: 16, height: 16))
        let service = DrawThingsLoopbackService(
            catalog: model.specification, tensor: tensor,
            expectedConfiguration: try configuration.toFlatBufferData(), loras: loras
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
            #expect(discovered.loras == loras)
            let image = try await transport.generate(
                payload: DrawThingsPayload(
                    connection: connection, specification: discovered.models,
                    configuration: configuration, loraSpecifications: discovered.loras),
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
