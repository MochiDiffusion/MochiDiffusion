import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Mochi_Diffusion

/// Pins the per-image record each engine builds: it holds the values that
/// reached the pipeline, and leaves out what the image did not use instead of
/// filling it with a default.
struct GenerationMetadataTests {
    private let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private static func request(
        engine: EngineID,
        payload: any Sendable,
        metadataFields: Set<MetadataField>,
        inputImageNames: [String?] = []
    ) -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: engine, key: "model"),
            displayName: "model",
            metadataFields: metadataFields,
            payload: payload,
            prompt: "a red cube",
            negativePrompt: "blur",
            size: CGSize(width: 8, height: 8),
            startingImageData: nil,
            inputImageData: [],
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: inputImageNames,
            strength: nil,
            stepCount: nil,
            guidanceScale: nil,
            scheduler: nil,
            quality: nil,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 7,
            numberOfImages: 1,
            imageDir: "/tmp"
        )
    }

    // MARK: - Core ML

    private func coreMLConfig(startingImage: CGImage?, controlNets: [String]) throws
        -> CoreMLGenerationConfig
    {
        let url = try temp.subdirectory("sd")
        try makeSDModelFixture(at: url)
        let model = try #require(SDModel(url: url, name: "sd", controlNet: []))
        return CoreMLGenerationConfig(
            prompt: "a red cube",
            negativePrompt: "",
            startingImage: startingImage,
            startingImageName: "start.png",
            controlNetImageName: "edges.png",
            controlNetInputs: [],
            model: model,
            mlComputeUnit: .cpuAndGPU,
            controlNets: controlNets,
            strength: 0.42,
            stepCount: 30,
            guidanceScale: 7.3,
            disableSafety: false,
            scheduler: .dpmSolverMultistepScheduler,
            useDenoisedIntermediates: false,
            seed: 7,
            numberOfImages: 1
        )
    }

    @Test("A Core ML image records its starting image, strength and ControlNet when they ran")
    func coreMLUsedInputs() throws {
        let config = try coreMLConfig(startingImage: makeCGImage(), controlNets: ["canny"])
        let request = Self.request(engine: .coreMLStableDiffusion, payload: "", metadataFields: [])

        let metadata = CoreMLEngineRuntime.metadata(
            request: request, config: config, width: 512, height: 512, seed: 42,
            generatedDate: Date())

        #expect(metadata.startingImage == "start.png")
        #expect(metadata.strength == 0.42)
        #expect(metadata.controlNet == "canny")
        #expect(metadata.controlNetImage == "edges.png")
        #expect(metadata.guidanceScale == 7.3)
        #expect(metadata.negativePrompt == "")
        #expect(metadata.seed == 42)
        #expect(metadata.inputImages == nil)
        #expect(metadata.architecture == SDModel.ModelType.sd15.displayName)
    }

    @Test("A starting image or ControlNet that never reached the pipeline is not recorded")
    func coreMLDroppedInputs() throws {
        let config = try coreMLConfig(startingImage: nil, controlNets: [])
        let request = Self.request(engine: .coreMLStableDiffusion, payload: "", metadataFields: [])

        let metadata = CoreMLEngineRuntime.metadata(
            request: request, config: config, width: 512, height: 512, seed: 42,
            generatedDate: Date())

        #expect(metadata.startingImage == nil)
        #expect(metadata.strength == nil)
        #expect(metadata.controlNet == nil)
        #expect(metadata.controlNetImage == nil)
    }

    // MARK: - Iris

    @Test(
        "Iris families are detected by the rules Iris applies",
        arguments: [
            (nil as String?, nil as String?, IrisModelFamily.fluxKlein),
            (#"{"_class_name": "Flux2KleinPipeline", "is_distilled": true}"#, nil, .fluxKlein),
            (#"{"_class_name": "Flux2KleinPipeline"}"#, nil, .fluxKleinBase),
            (#"{"_class_name": "ZImagePipeline"}"#, nil, .zImageTurbo),
            (nil, #"{"cap_feat_dim": 2560}"#, .zImageTurbo),
        ]
    )
    func irisFamilyDetection(index: String?, transformer: String?, family: IrisModelFamily) throws {
        let url = try temp.subdirectory("model")
        try makeKleinModelFixture(at: url)
        if let index { try writeFile(index, to: url.appending(path: "model_index.json")) }
        if let transformer {
            try writeFile(transformer, to: url.appending(components: "transformer", "config.json"))
        }

        let model = try #require(IrisFluxKleinModel(url: url, name: "model"))

        #expect(model.family == family)
        #expect(model.constraints.steps.resolved(1) == family.stepCount)
        #expect(model.constraints.guidanceScale.resolved(20) == family.guidanceScale)
    }

    @Test("Each Iris family pins the steps and guidance Iris runs")
    func irisFamilyDefaults() {
        #expect(IrisModelFamily.allCases.map(\.stepCount) == [4, 50, 9])
        #expect(IrisModelFamily.allCases.map(\.guidanceScale) == [1, 4, 1])
    }

    @Test("An Iris image records its family's values and keeps unnamed references in place")
    func irisMetadata() {
        let payload = IrisGenerationPayload(
            modelDirectory: "/models/base", family: .fluxKleinBase, stepCount: 50, guidanceScale: 4,
            scheduler: .discreteFlowScheduler)
        let request = Self.request(
            engine: .iris, payload: payload, metadataFields: IrisFluxKleinModel.metadataFields,
            inputImageNames: ["cat.png", nil, "dog.png"])

        let metadata = IrisEngineRuntime.metadata(
            request: request, payload: payload, width: 1024, height: 768, seed: 9,
            generatedDate: Date())

        #expect(metadata.inputImages == ["cat.png", "", "dog.png"])
        #expect(metadata.negativePrompt == nil)
        #expect(metadata.steps == 50)
        #expect(metadata.guidanceScale == 4)
        #expect(metadata.architecture == "FLUX.2 Klein Base")
        #expect(metadata.strength == nil)
    }

    @Test("A filename leaves out a seed the image does not have")
    func filenameWithoutSeed() {
        #expect(imageFilenameWithoutExtension(prompt: "a cat", seed: nil, count: 3) == "a cat.3")
        #expect(imageFilenameWithoutExtension(prompt: "a cat", seed: 7, count: 3) == "a cat.3.7")
    }
}
