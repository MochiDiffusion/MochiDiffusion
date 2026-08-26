//
//  ModelDiscoveryTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins how a directory on disk is recognised as a particular kind of model.
///
/// This logic is currently split between `SDModel.init?`, `IrisFluxKleinModel.init?`
/// and the sniffing chain in `ModelRepository.load`. It is the part most likely to
/// move behind a per-provider `claims(url:)` hook, so the observable outcomes are
/// captured here first.
struct SDModelDiscoveryTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    @Test("A directory without Unet metadata is not a Core ML SD model")
    func rejectsDirectoryWithoutUnetMetadata() throws {
        let url = try temp.subdirectory("empty")
        #expect(SDModel(url: url, name: "empty", controlNet: []) == nil)
    }

    @Test(
        "Attention type is read from the Unet operation histogram",
        arguments: [SDModelAttentionType.original, .splitEinsum]
    )
    func identifiesAttentionType(attention: SDModelAttentionType) throws {
        let url = try temp.subdirectory("model")
        try makeSDModelFixture(at: url, attention: attention)

        let model = try #require(SDModel(url: url, name: "model", controlNet: []))
        #expect(model.attention == attention)
    }

    @Test("Model family is inferred from the Unet input schema")
    func identifiesModelFamily() throws {
        let sd15 = try temp.subdirectory("sd15")
        try makeSDModelFixture(at: sd15)
        #expect(SDModel(url: sd15, name: "sd15", controlNet: [])?.type == .sd15)

        let sdxl = try temp.subdirectory("sdxl")
        try makeSDModelFixture(at: sdxl, extraUnetInputs: ["time_ids", "text_embeds"])
        #expect(SDModel(url: sdxl, name: "sdxl", controlNet: [])?.type == .sdxl)

        let sd3 = try temp.subdirectory("sd3")
        try makeSDModelFixture(
            at: sd3,
            unetName: "MultiModalDiffusionTransformer.mlmodelc",
            extraUnetInputs: ["latent_image_embeddings"]
        )
        #expect(SDModel(url: sd3, name: "sd3", controlNet: [])?.type == .sd3)
    }

    @Test("Fixed input size is read from the VAE encoder input shape")
    func identifiesFixedInputSize() throws {
        let url = try temp.subdirectory("model")
        try makeSDModelFixture(at: url, inputSize: CGSize(width: 768, height: 512))

        let model = try #require(SDModel(url: url, name: "model", controlNet: []))
        #expect(model.inputSize == CGSize(width: 768, height: 512))
    }

    @Test("A model with no VAE encoder metadata has no fixed input size")
    func missingVAEEncoderMeansFreeformSize() throws {
        let url = try temp.subdirectory("model")
        try makeSDModelFixture(at: url, inputSize: nil)

        let model = try #require(SDModel(url: url, name: "model", controlNet: []))
        #expect(model.inputSize == nil)
    }

    @Test("ControlNets are offered only when size and attention both match")
    func filtersControlNetsBySizeAndAttention() throws {
        let controlNetDir = try temp.subdirectory("controlnet")
        let matching = controlNetDir.appending(path: "matching.mlmodelc")
        let wrongSize = controlNetDir.appending(path: "wrong-size.mlmodelc")
        let wrongAttention = controlNetDir.appending(path: "wrong-attention.mlmodelc")
        try makeControlNetFixture(at: matching, size: CGSize(width: 512, height: 512))
        try makeControlNetFixture(at: wrongSize, size: CGSize(width: 768, height: 768))
        try makeControlNetFixture(
            at: wrongAttention,
            size: CGSize(width: 512, height: 512),
            attention: .splitEinsum
        )

        let controlNets = try [matching, wrongSize, wrongAttention].map {
            try #require(SDControlNet(url: $0))
        }

        let modelDir = try temp.subdirectory("model")
        try makeSDModelFixture(
            at: modelDir,
            attention: .original,
            inputSize: CGSize(width: 512, height: 512)
        )

        let model = try #require(SDModel(url: modelDir, name: "model", controlNet: controlNets))
        #expect(model.controlNet == ["matching"])
    }

    @Test("A model with no fixed input size is offered no ControlNets")
    func freeformModelGetsNoControlNets() throws {
        let controlNetDir = try temp.subdirectory("controlnet")
        let controlNetURL = controlNetDir.appending(path: "matching.mlmodelc")
        try makeControlNetFixture(at: controlNetURL)
        let controlNet = try #require(SDControlNet(url: controlNetURL))

        let modelDir = try temp.subdirectory("model")
        try makeSDModelFixture(at: modelDir, inputSize: nil)

        let model = try #require(SDModel(url: modelDir, name: "model", controlNet: [controlNet]))
        #expect(model.controlNet.isEmpty)
    }
}

struct IrisFluxKleinDiscoveryTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    @Test("A complete Klein directory with unsharded weights is recognised")
    func acceptsSingleFileWeights() throws {
        let url = try temp.subdirectory("klein")
        try makeKleinModelFixture(at: url, weights: .single)

        let model = try #require(IrisFluxKleinModel(url: url, name: "klein"))
        #expect(model.id == url)
        #expect(model.promptTokenLimit == 512)
        #expect(model.tokenizerModelDir == url.appending(path: "tokenizer"))
    }

    @Test("A complete Klein directory with sharded weights is recognised")
    func acceptsShardedWeights() throws {
        let url = try temp.subdirectory("klein")
        try makeKleinModelFixture(at: url, weights: .sharded)

        #expect(IrisFluxKleinModel(url: url, name: "klein") != nil)
    }

    @Test("Klein weights are required")
    func rejectsMissingWeights() throws {
        let url = try temp.subdirectory("klein")
        try makeKleinModelFixture(at: url, weights: .missing)

        #expect(IrisFluxKleinModel(url: url, name: "klein") == nil)
    }

    @Test(
        "Every required Klein config file is required",
        arguments: [
            ["text_encoder", "config.json"],
            ["tokenizer", "tokenizer.json"],
            ["tokenizer", "chat_template.jinja"],
            ["transformer", "config.json"],
            ["vae", "diffusion_pytorch_model.safetensors"],
        ]
    )
    func rejectsIncompleteDirectory(omitted: [String]) throws {
        let url = try temp.subdirectory("klein-\(omitted.joined(separator: "-"))")
        try makeKleinModelFixture(at: url, omitting: [omitted])

        #expect(IrisFluxKleinModel(url: url, name: "klein") == nil)
    }

    @Test("Klein declares only the capabilities it can honour")
    func declaresCapabilities() {
        let capabilities = IrisFluxKleinModel.generationCapabilities
        #expect(capabilities.contains(.startingImage))
        #expect(!capabilities.contains(.controlNet))
        #expect(!capabilities.contains(.negativePrompt))
        #expect(!capabilities.contains(.guidanceScale))
    }
}

struct ModelRepositoryTests {
    let temp: TempDirectory
    let modelDir: URL
    let controlNetDir: URL
    let repository = ModelRepository()

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
    }

    @Test("Discovery returns both model kinds, sorted case-insensitively by name")
    func loadsMixedModelDirectory() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "B-coreml-model"))
        try makeKleinModelFixture(at: modelDir.appending(path: "a-klein-model"))

        let models = try await repository.load(modelDir: modelDir, controlNetDir: controlNetDir)

        #expect(models.map(\.name) == ["a-klein-model", "B-coreml-model"])
        #expect(models[0] is IrisFluxKleinModel)
        #expect(models[1] is SDModel)
    }

    @Test("Directories that match no known model kind are skipped")
    func ignoresUnrecognisedDirectories() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "real-model"))
        try writeFile("{}", to: modelDir.appending(components: "not-a-model", "readme.txt"))

        let models = try await repository.load(modelDir: modelDir, controlNetDir: controlNetDir)

        #expect(models.map(\.name) == ["real-model"])
    }

    @Test("An empty model directory reports that no models were found")
    func emptyDirectoryThrows() async throws {
        await #expect(throws: SDImageGenerator.GeneratorError.noModelsFound) {
            _ = try await repository.load(modelDir: modelDir, controlNetDir: controlNetDir)
        }
    }

    @Test("A directory satisfying both sniffers is claimed by Klein first")
    func kleinTakesPrecedenceOverCoreML() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)

        let models = try await repository.load(modelDir: modelDir, controlNetDir: controlNetDir)

        #expect(models.count == 1)
        #expect(models[0] is IrisFluxKleinModel)
    }

    @Test("A ControlNet-capable model gets a controlnet symlink into the shared folder")
    func createsControlNetSymlink() async throws {
        let modelURL = modelDir.appending(path: "controlled-model")
        try makeSDModelFixture(at: modelURL, unetName: "ControlledUnet.mlmodelc")

        _ = try await repository.load(modelDir: modelDir, controlNetDir: controlNetDir)

        let symlink = modelURL.appending(path: "controlnet")
        let destination = try FileManager.default.destinationOfSymbolicLink(
            atPath: symlink.path(percentEncoded: false)
        )
        #expect(destination == controlNetDir.path(percentEncoded: false))
    }

    @Test("Models that no longer exist on disk are reported as missing")
    func detectsRemovedModel() async throws {
        let modelURL = modelDir.appending(path: "model")
        try makeSDModelFixture(at: modelURL)
        let model = try #require(SDModel(url: modelURL, name: "model", controlNet: []))

        #expect(await repository.modelExists(model))

        try FileManager.default.removeItem(at: modelURL)
        #expect(await repository.modelExists(model) == false)
    }
}
