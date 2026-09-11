//
//  GenerationConfigRestorationTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the shared gallery/queue operation that turns recorded generation state
/// back into a sidebar configuration.
@MainActor
@Suite(.serialized)
struct GenerationConfigRestorationTests {
    let temp: TempDirectory
    let tempDefaults: TempDefaults
    let configStore: ConfigStore
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        tempDefaults = TempDefaults()
        configStore = ConfigStore(store: tempDefaults.defaults)
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
        configStore.modelDir = modelDir.path(percentEncoded: false)
        configStore.controlNetDir = controlNetDir.path(percentEncoded: false)
    }

    private func makeController(gallery: ImageGallery = ImageGallery()) -> GenerationController {
        let secrets = InMemorySecretStore([OpenAIImageEngine.secretAccount: "sk-test"])
        return makeTestGenerationController(
            configStore: configStore,
            imageGallery: gallery,
            engineRegistry: EngineRegistry(secrets: secrets),
            startsObserving: false
        )
    }

    private func selectModel(
        _ name: String,
        on controller: GenerationController
    ) throws {
        controller.currentModelId = try #require(controller.models.first { $0.name == name }?.id)
    }

    @Test("A queued unnamed starting image keeps its role and ControlNet")
    func queuedCoreMLRestoreKeepsExplicitImageRoles() async throws {
        let modelURL = modelDir.appending(path: "core-portrait")
        try makeSDModelFixture(
            at: modelURL,
            inputSize: CGSize(width: 512, height: 768),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(
            at: controlNetDir.appending(path: "canny.mlmodelc"),
            size: CGSize(width: 512, height: 768)
        )

        let controller = makeController()
        await controller.loadModels()
        try selectModel("core-portrait", on: controller)
        controller.setStartingImage(image: makeCGImage(width: 12, height: 8))
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(
            image: makeCGImage(width: 8, height: 12),
            filename: "guide.png"
        )
        configStore.strength = 0.35
        controller.numberOfImages = 3
        let source = try #require(controller.buildGenerationRequest())

        #expect(source.startingImageData != nil)
        #expect(source.startingImageName == nil)
        #expect(source.inputImageData.isEmpty)

        try selectModel("gpt-image-2", on: controller)
        controller.addInputImage(image: makeCGImage(), filename: "stale.png")
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == source.modelID)
        #expect(controller.startingImage != nil)
        #expect(controller.startingImage?.name == nil)
        #expect(controller.inputImages.isEmpty)
        #expect(controller.currentControlNets.first?.name == "canny")
        #expect(controller.currentControlNets.first?.imageFilename == "guide.png")
        #expect(configStore.width == 512)
        #expect(configStore.height == 768)
        #expect(configStore.strength == Double(try #require(source.strength)))
        #expect(controller.numberOfImages == 3)

        let restored = try #require(controller.buildGenerationRequest())
        #expect(restored.modelID == source.modelID)
        #expect(restored.startingImageData != nil)
        #expect(restored.inputImageData.isEmpty)
        #expect(restored.controlNetNames == source.controlNetNames)
        #expect(restored.controlNetImageNames == source.controlNetImageNames)
    }

    @Test("Queued Iris references keep exact values and positional names")
    func queuedIrisRestoreKeepsExactRequest() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        try makeKleinModelFixture(at: modelDir.appending(path: "klein"))

        let controller = makeController()
        await controller.loadModels()
        try selectModel("klein", on: controller)
        configStore.width = 640
        configStore.height = 384
        controller.numberOfImages = 2
        controller.seed = 4242
        controller.addInputImage(image: makeCGImage(width: 12, height: 8))
        controller.addInputImage(
            image: makeCGImage(width: 8, height: 12),
            filename: "second.png"
        )
        let source = try #require(controller.buildGenerationRequest())

        #expect(source.inputImageNames == [nil, "second.png"])

        try selectModel("core", on: controller)
        controller.setStartingImage(image: makeCGImage(), filename: "stale.png")
        configStore.steps = 19
        configStore.scheduler = .pndmScheduler
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == source.modelID)
        #expect(controller.startingImage == nil)
        #expect(controller.inputImages.map(\.name) == [nil, "second.png"])
        #expect(configStore.width == Int(source.size.width))
        #expect(configStore.height == Int(source.size.height))
        #expect(configStore.steps == Double(try #require(source.stepCount)))
        #expect(configStore.scheduler == source.scheduler)
        #expect(controller.seed == source.seed)
        #expect(controller.numberOfImages == Double(source.numberOfImages))

        let restored = try #require(controller.buildGenerationRequest())
        #expect(restored.modelID == source.modelID)
        #expect(restored.size == source.size)
        #expect(restored.stepCount == source.stepCount)
        #expect(restored.scheduler == source.scheduler)
        #expect(restored.inputImageNames == source.inputImageNames)
        #expect(restored.inputImageData.count == source.inputImageData.count)
    }

    @Test("A gallery restore loads path-backed OpenAI references")
    func galleryRestoreLoadsReferencesAndIntersectsConstraints() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let referenceURL = temp.appending("reference.png")
        try writePNG(caption: "", to: referenceURL, image: makeCGImage(width: 13, height: 7))

        let gallery = ImageGallery()
        let reference = SDImage(image: nil, aspectRatio: 13.0 / 7.0, path: referenceURL.path)
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "gpt-image-2"
        source.engine = EngineID.openAI.rawValue
        source.modelKey = "gpt-image-2"
        source.prompt = "restored prompt"
        source.negativePrompt = "not supported"
        source.steps = 99
        source.scheduler = .pndmScheduler
        source.quality = ImageQuality.high.rawValue
        source.inputImages = ["RÉFERENCE.PNG"]
        let fields: Set<MetadataField> = [
            .model, .engine, .modelKey, .prompt, .negativePrompt, .steps, .scheduler,
            .quality, .inputImages,
        ]
        gallery.replaceAll([
            (image: reference, metadataFields: []),
            (image: source, metadataFields: fields),
        ])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("core", on: controller)
        configStore.negativePrompt = "keep me"
        configStore.steps = 17
        configStore.scheduler = .discreteFlowScheduler
        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == ModelID(engine: .openAI, key: "gpt-image-2"))
        #expect(configStore.prompt == "restored prompt")
        #expect(configStore.negativePrompt == "keep me")
        #expect(configStore.steps == 17)
        #expect(configStore.scheduler == .discreteFlowScheduler)
        #expect(configStore.quality == .high)
        #expect(controller.inputImages.count == 1)
        #expect(controller.inputImages.first?.name == "RÉFERENCE.PNG")
        #expect(controller.inputImages.first?.image.width == 13)
        #expect(controller.inputImages.first?.image.height == 7)
    }

    @Test("A missing exact model retains the current model and its constraints")
    func missingExactModelUsesCurrentConstraints() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "core"))
        let gallery = ImageGallery()
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "core"
        source.engine = EngineID.coreMLStableDiffusion.rawValue
        source.modelKey = "missing"
        source.prompt = "safe to copy"
        source.steps = 99
        let fields: Set<MetadataField> = [.model, .engine, .modelKey, .prompt, .steps]
        gallery.replaceAll([(image: source, metadataFields: fields)])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)
        configStore.steps = 21
        controller.addInputImage(image: makeCGImage(), filename: "stale.png")
        let selected = controller.currentModelId

        await controller.copyToPrompt(source)

        #expect(controller.currentModelId == selected)
        #expect(configStore.prompt == "safe to copy")
        #expect(configStore.steps == 21)
        #expect(controller.inputImages.isEmpty)
    }

    @Test("Legacy gallery metadata falls back to an unambiguous display name")
    func legacyModelNameFallbackStillWorks() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "legacy-core"))
        let gallery = ImageGallery()
        var source = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        source.model = "legacy-core"
        gallery.replaceAll([(image: source, metadataFields: [.model])])

        let controller = makeController(gallery: gallery)
        await controller.loadModels()
        try selectModel("gpt-image-2", on: controller)

        await controller.copyToPrompt(source)

        #expect(
            controller.currentModelId
                == ModelID(engine: .coreMLStableDiffusion, key: "legacy-core")
        )
    }
}
