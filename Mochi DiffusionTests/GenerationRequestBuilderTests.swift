//
//  GenerationRequestBuilderTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the request `GenerationController.buildGenerationRequest()` builds today,
/// field by field.
///
/// Phase 2 of `Multi-Engine-Design.md` moves this function's per-engine branches
/// into per-engine `plan` implementations. That is a behaviour-preserving
/// refactor, so "the request is unchanged" is the only meaningful definition of
/// success — and until now nothing asserted what the request even is.
///
/// These tests describe current behaviour, including the parts that are odd. Where
/// something looks wrong rather than merely surprising it is called out in a
/// comment, so the Phase 4 constraint work has a list to fix rather than a
/// contract to preserve.
@MainActor
struct GenerationRequestBuilderTests {
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

    /// `startsObserving: false` keeps the controller from owning a background
    /// model load. A stray reload reassigns `currentModelId`, whose `didSet`
    /// clears `currentControlNets`, which would empty state these tests just set.
    private func makeController() -> GenerationController {
        GenerationController(
            configStore: configStore,
            modelRepository: ModelRepository(),
            imageRepository: ImageRepository(),
            startsObserving: false
        )
    }

    /// Loads models and selects `name`. Selection happens last because
    /// `currentModelId.didSet` resets ControlNet state, so callers configure
    /// ControlNet inputs after this returns.
    private func makeControllerSelecting(_ name: String) async throws -> GenerationController {
        let controller = makeController()
        await controller.loadModels()
        let model = try #require(
            controller.models.first { $0.name == name },
            "fixture \(name) was not discovered"
        )
        controller.currentModelId = model.id
        return controller
    }

    /// Values chosen to differ from every `ConfigStore` default, so a field that
    /// silently stops being read shows up as a mismatch rather than a pass.
    private func applyDistinctiveConfig() {
        configStore.prompt = "a cat wearing a hat"
        configStore.negativePrompt = "blurry, low quality"
        configStore.strength = 0.42
        configStore.steps = 23
        configStore.guidanceScale = 6.5
        configStore.width = 640
        configStore.height = 384
        configStore.scheduler = .pndmScheduler
        configStore.showGenerationPreview = false
        configStore.safetyChecker = true
        configStore.reduceMemory = true
        configStore.imageDir = "/tmp/mochi-test-images"
        configStore.imageType = "heic"
        configStore.mlComputeUnitPreference = .cpuAndGPU
    }

    // MARK: - No model

    @Test("No selected model builds no request")
    func noModelBuildsNothing() async throws {
        let controller = makeController()
        await controller.loadModels()

        controller.currentModelId = nil

        #expect(controller.buildGenerationRequest() == nil)
    }

    // MARK: - Core ML Stable Diffusion

    @Test("Every scalar option reaches the request unchanged")
    func scalarsAreCarriedThrough() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        applyDistinctiveConfig()
        let controller = try await makeControllerSelecting("sd-model")
        controller.numberOfImages = 3
        controller.seed = 987_654_321

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.prompt == "a cat wearing a hat")
        #expect(request.negativePrompt == "blurry, low quality")
        #expect(request.strength == 0.42)
        #expect(request.stepCount == 23)
        #expect(request.guidanceScale == 6.5)
        #expect(request.scheduler == .pndmScheduler)
        #expect(request.seed == 987_654_321)
        #expect(request.numberOfImages == 3)
        #expect(request.imageDir == "/tmp/mochi-test-images")
        #expect(request.imageType == "heic")
        // Both of these invert their config value; a sign flip would otherwise
        // be invisible.
        #expect(request.disableSafety == false)  // safetyChecker == true
        #expect(request.useDenoisedIntermediates == false)  // showGenerationPreview == false
    }

    @Test("A fixed-size model records the size it will actually produce")
    func sizeIsTheModelsFixedSize() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            inputSize: CGSize(width: 512, height: 768)
        )
        configStore.width = 640
        configStore.height = 384
        let controller = try await makeControllerSelecting("sd-model")

        let request = try #require(controller.buildGenerationRequest())

        // The sidebar's 640x384 is unreachable for this model: it always emits
        // 512x768. JobQueueView displays request.size and copies it back to the
        // sidebar, so recording the configured size here put a number on screen
        // that no generated image would ever match.
        #expect(request.size == CGSize(width: 512, height: 768))
    }

    @Test("A freeform model records the configured size")
    func sizeIsConfiguredWhenModelHasNoFixedSize() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"), inputSize: nil)
        configStore.width = 640
        configStore.height = 384
        let controller = try await makeControllerSelecting("sd-model")

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.size == CGSize(width: 640, height: 384))
    }

    @Test("A Core ML pipeline carries the model, compute unit and memory flag")
    func coreMLPipelineIsConfigured() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            attention: .splitEinsum
        )
        configStore.reduceMemory = true
        configStore.mlComputeUnitPreference = .auto
        let controller = try await makeControllerSelecting("sd-model")

        let request = try #require(controller.buildGenerationRequest())

        guard
            case .sd(let model, let computeUnit, let controlNets, let reduceMemory) =
                request.pipeline
        else {
            Issue.record("expected an .sd pipeline, got \(request.pipeline)")
            return
        }
        #expect(model.name == "sd-model")
        // .auto follows the model's attention type.
        #expect(computeUnit == .cpuAndNeuralEngine)
        #expect(controlNets.isEmpty)
        #expect(reduceMemory)
    }

    @Test("An explicit compute unit preference overrides the model's attention type")
    func explicitComputeUnitWins() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            attention: .splitEinsum
        )
        configStore.mlComputeUnitPreference = .all
        let controller = try await makeControllerSelecting("sd-model")

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.pipeline.mlComputeUnit == .all)
    }

    @Test("A starting image is scaled to a fixed-size model's input size")
    func startingImageIsScaledToModelInputSize() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            inputSize: CGSize(width: 512, height: 768)
        )
        configStore.width = 640
        configStore.height = 384
        let controller = try await makeControllerSelecting("sd-model")
        controller.setStartingImage(
            image: makeCGImage(width: 40, height: 20), filename: "start.png")

        let request = try #require(controller.buildGenerationRequest())

        let data = try #require(request.startingImageData)
        #expect(pixelSize(of: data) == CGSize(width: 512, height: 768))
        #expect(request.startingImageName == "start.png")
        // Core ML SD records a starting image; the Iris path records input images.
        #expect(request.inputImageNames.isEmpty)
    }

    @Test("A starting image is scaled to the configured size when the model has none")
    func startingImageIsScaledToConfiguredSize() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"), inputSize: nil)
        configStore.width = 320
        configStore.height = 448
        let controller = try await makeControllerSelecting("sd-model")
        controller.setStartingImage(
            image: makeCGImage(width: 40, height: 20), filename: "start.png")

        let request = try #require(controller.buildGenerationRequest())

        let data = try #require(request.startingImageData)
        #expect(pixelSize(of: data) == CGSize(width: 320, height: 448))
    }

    @Test("A blank starting image filename is normalised away")
    func blankStartingImageFilenameBecomesNil() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let controller = try await makeControllerSelecting("sd-model")
        controller.setStartingImage(image: makeCGImage(), filename: "   ")

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.startingImageName == nil)
        #expect(request.startingImageData != nil)
    }

    // MARK: - ControlNet

    @Test("A named ControlNet with an image reaches the request")
    func controlNetIsCarriedThrough() async throws {
        let modelURL = modelDir.appending(path: "sd-model")
        try makeSDModelFixture(
            at: modelURL,
            inputSize: CGSize(width: 512, height: 512),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = try await makeControllerSelecting("sd-model")
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(image: makeCGImage(width: 64, height: 64), filename: "c.png")

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.pipeline.controlNets == ["canny"])
        #expect(request.controlNetImageNames == ["c.png"])
        let data = try #require(request.controlNetInputs.first)
        #expect(pixelSize(of: data) == CGSize(width: 512, height: 512))
    }

    @Test(
        "A ControlNet input missing either its name or its image is dropped",
        arguments: [true, false]
    )
    func incompleteControlNetIsDropped(hasName: Bool) async throws {
        let modelURL = modelDir.appending(path: "sd-model")
        try makeSDModelFixture(at: modelURL, unetName: "ControlledUnet.mlmodelc")
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = try await makeControllerSelecting("sd-model")
        if hasName {
            await controller.setControlNet(name: "canny")
        } else {
            await controller.setControlNet(image: makeCGImage(), filename: "c.png")
        }

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.controlNetInputs.isEmpty)
        #expect(request.pipeline.controlNets.isEmpty)
        #expect(request.controlNetImageNames.isEmpty)
    }

    @Test("A model with no fixed input size drops ControlNet inputs entirely")
    func freeformModelDropsControlNet() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            inputSize: nil,
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = try await makeControllerSelecting("sd-model")
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(image: makeCGImage(), filename: "c.png")

        let request = try #require(controller.buildGenerationRequest())

        // The whole ControlNet loop is gated on the model having a fixed input
        // size, so a fully configured ControlNet is silently discarded here.
        // Phase 4 should express this as an unsupported constraint that hides the
        // control instead.
        #expect(request.controlNetInputs.isEmpty)
        #expect(request.pipeline.controlNets.isEmpty)
    }

    @Test("A ControlNet image with no filename still contributes its input")
    func controlNetImageWithoutFilename() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "sd-model"),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = try await makeControllerSelecting("sd-model")
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(image: makeCGImage(), filename: nil)

        let request = try #require(controller.buildGenerationRequest())

        // Names and image names are appended to separate arrays, so a missing
        // filename leaves them different lengths and positionally uncorrelated.
        #expect(request.controlNetInputs.count == 1)
        #expect(request.pipeline.controlNets == ["canny"])
        #expect(request.controlNetImageNames.isEmpty)
    }

    // MARK: - Iris FLUX.2 Klein

    @Test("A Klein model builds an Iris pipeline pointed at its directory")
    func kleinBuildsIrisPipeline() async throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        let controller = try await makeControllerSelecting("klein-model")

        let request = try #require(controller.buildGenerationRequest())

        guard case .iris(let dir, let family) = request.pipeline else {
            Issue.record("expected an .iris pipeline, got \(request.pipeline)")
            return
        }
        // Compared against the discovered model's own url rather than a
        // reconstructed path: discovery returns symlink-resolved URLs with a
        // trailing slash, so `modelDir.appending(path:)` names the same directory
        // in a form that does not compare equal. The string handed to
        // `iris_load_dir` therefore carries that trailing slash.
        let model = try #require(controller.currentModel)
        #expect(dir == model.url.path(percentEncoded: false))
        #expect(dir.hasSuffix("/klein-model/"))
        #expect(family == .fluxKlein)
    }

    @Test("Klein records the starting image as an input image, not a starting image")
    func kleinRecordsInputImages() async throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        configStore.width = 512
        configStore.height = 512
        let controller = try await makeControllerSelecting("klein-model")
        controller.setStartingImage(image: makeCGImage(width: 40, height: 20), filename: "in.png")

        let request = try #require(controller.buildGenerationRequest())

        // The same UI state lands in a different field per engine. This is the
        // divergence Phase 2's per-engine `plan` has to preserve exactly.
        #expect(request.startingImageName == nil)
        #expect(request.inputImageNames == ["in.png"])
        let data = try #require(request.startingImageData)
        #expect(pixelSize(of: data) == CGSize(width: 512, height: 512))
        // Klein models declare no fixed input size, so the configured size
        // reaches the request — and unlike Core ML, the Iris generator actually
        // uses it as the generation dimensions.
        #expect(request.size == CGSize(width: 512, height: 512))
    }

    @Test("Klein never carries ControlNet state")
    func kleinHasNoControlNet() async throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = try await makeControllerSelecting("klein-model")
        await controller.setControlNet(name: "canny")
        await controller.setControlNet(image: makeCGImage(), filename: "c.png")

        let request = try #require(controller.buildGenerationRequest())

        #expect(request.controlNetInputs.isEmpty)
        #expect(request.controlNetImageNames.isEmpty)
        #expect(request.pipeline.controlNets.isEmpty)
    }

    @Test("Klein still receives options its pipeline ignores")
    func kleinReceivesIgnoredOptions() async throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        applyDistinctiveConfig()
        let controller = try await makeControllerSelecting("klein-model")

        let request = try #require(controller.buildGenerationRequest())

        // Klein declares neither negativePrompt, guidanceScale nor scheduler, yet
        // the request carries all three and the pipeline overrides steps and
        // scheduler downstream. This is precisely the "the UI shows one number and
        // the image records another" problem Phase 4 removes; pinned here so the
        // Phase 2 move does not accidentally change it early.
        #expect(request.negativePrompt == "blurry, low quality")
        #expect(request.guidanceScale == 6.5)
        #expect(request.stepCount == 23)
        #expect(request.scheduler == .pndmScheduler)
        #expect(request.pipeline.effectiveStepCount(requestedStepCount: 23) == 4)
        #expect(
            request.pipeline.effectiveScheduler(requestedScheduler: .pndmScheduler)
                == .discreteFlowScheduler
        )
    }

    // MARK: - Seed

    @Test("A non-zero seed is used verbatim")
    func explicitSeedIsPreserved() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let controller = try await makeControllerSelecting("sd-model")
        controller.seed = 4242

        #expect(try #require(controller.buildGenerationRequest()).seed == 4242)
    }

    @Test("A zero seed is replaced with a random one per request")
    func zeroSeedIsRandomised() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let controller = try await makeControllerSelecting("sd-model")
        controller.seed = 0

        let seeds = try (0..<8).map { _ in
            try #require(controller.buildGenerationRequest()).seed
        }

        // Every request gets its own seed, and zero never survives to the request.
        #expect(!seeds.contains(0))
        #expect(Set(seeds).count > 1)
        // The controller's own seed is left alone, so the UI keeps showing 0.
        #expect(controller.seed == 0)
    }
}
