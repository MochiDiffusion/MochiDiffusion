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
/// Recognition lives in `SDModel.init?` and `IrisFluxKleinModel.init?`. Each
/// engine applies only its own rules — see `EngineDiscoveryTests` for the
/// discovery those feed.
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

    @Test(
        "Malformed VAE encoder shapes reject the model",
        arguments: [
            "[1, 3]",
            "[1, 3, height, 768]",
            "[1, 3, 512, 768, 1]",
            "[1, 3, 0, 768]",
        ]
    )
    func rejectsMalformedVAEEncoderShape(shape: String) throws {
        let url = try temp.subdirectory(UUID().uuidString)
        try makeSDModelFixture(at: url, inputSize: nil, inputShape: shape)

        #expect(SDModel(url: url, name: "model", controlNet: []) == nil)
    }

    @Test("A valid VAE encoder shape does not require spaces after commas")
    func acceptsCompactVAEEncoderShape() throws {
        let url = try temp.subdirectory("compact-shape")
        try makeSDModelFixture(at: url, inputSize: nil, inputShape: "[1,3,512,768]")

        let model = try #require(SDModel(url: url, name: "model", controlNet: []))
        #expect(model.inputSize == CGSize(width: 768, height: 512))
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

    @Test(
        "Malformed ControlNet shapes reject the ControlNet",
        arguments: [
            "[1, 3]",
            "[invalid, 1, 3, 512, 768]",
            "[1, 3, 512, 768, 1]",
            "[1, 3, -512, 768]",
        ]
    )
    func rejectsMalformedControlNetShape(shape: String) throws {
        let url = temp.url.appending(path: "\(UUID().uuidString).mlmodelc")
        try makeControlNetFixture(at: url, shape: shape)

        #expect(SDControlNet(url: url) == nil)
    }

    @Test("A valid ControlNet shape does not require spaces after commas")
    func acceptsCompactControlNetShape() throws {
        let url = temp.url.appending(path: "compact.mlmodelc")
        try makeControlNetFixture(at: url, shape: "[1,3,512,768]")

        let controlNet = try #require(SDControlNet(url: url))
        #expect(controlNet.size == CGSize(width: 768, height: 512))
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
        #expect(model.id == ModelID(engine: .iris, key: "klein"))
        #expect(model.constraints.promptTokenLimit == 512)
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
        arguments: kleinRequiredConfigPaths
    )
    func rejectsIncompleteDirectory(omitted: [String]) throws {
        let url = try temp.subdirectory("klein-\(omitted.joined(separator: "-"))")
        try makeKleinModelFixture(at: url, omitting: [omitted])

        #expect(IrisFluxKleinModel(url: url, name: "klein") == nil)
    }

    /// Klein is distilled, which is what makes most of these unsupported rather
    /// than merely unused: no classifier-free guidance means no negative prompt
    /// and no guidance scale, and four steps on the flow-match scheduler are
    /// properties of the distillation rather than choices.
    @Test("Klein declares only what it can honour")
    func declaresConstraints() {
        let constraints = IrisFluxKleinModel.constraints

        #expect(!constraints.supportsNegativePrompt)
        #expect(constraints.steps == .pinned(4))
        #expect(constraints.scheduler == .pinned(.discreteFlowScheduler))
        #expect(constraints.guidanceScale == .pinned(1.0))
        #expect(constraints.controlNet == .unsupported)
        // References, not a denoising origin — so no starting image and no
        // strength to go with one.
        #expect(constraints.inputImages.isSupported)
        #expect(!constraints.startingImage.isSupported)
        #expect(constraints.startingImage.strength == .unsupported)
        #expect(constraints.size.isEditable)
        // Klein's image count is a plain loop, so it takes what it is given.
        #expect(constraints.numberOfImages.allowsValuesAboveBounds)
    }
}
