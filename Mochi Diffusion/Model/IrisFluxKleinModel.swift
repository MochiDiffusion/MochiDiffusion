//
//  IrisFluxKleinModel.swift
//  Mochi Diffusion
//

import Foundation

/// The model families Iris runs.
///
/// Detected by the same rules Iris applies when it loads a model directory, so
/// Mochi and Iris always agree on which family a model belongs to.
nonisolated enum IrisModelFamily: Sendable, Equatable, CaseIterable {
    /// FLUX.2 Klein, guidance-distilled.
    case fluxKlein
    /// FLUX.2 Klein base, which runs classifier-free guidance.
    case fluxKleinBase
    /// Z-Image Turbo, distilled.
    case zImageTurbo

    var displayName: String {
        switch self {
        case .fluxKlein: "FLUX.2 Klein"
        case .fluxKleinBase: "FLUX.2 Klein Base"
        case .zImageTurbo: "Z-Image Turbo"
        }
    }

    /// The step count Iris uses for the family when it is given none. Mochi
    /// pins this value, so the recorded count is the one that runs.
    var stepCount: Int {
        switch self {
        case .fluxKlein: 4
        case .fluxKleinBase: 50
        case .zImageTurbo: 9
        }
    }

    /// The classifier-free guidance scale the family runs at. Mochi passes no
    /// guidance, so Iris resolves its own default, and this value matches it.
    ///
    /// A distilled model runs no guidance pass. 1.0 is the scale at which the
    /// CFG formula `v_uncond + g * (v_cond - v_uncond)` reduces to `v_cond`, so
    /// it records "no guidance" as a scale. Iris stores Z-Image's setting as 0,
    /// meaning the same thing.
    var guidanceScale: Double {
        switch self {
        case .fluxKlein, .zImageTurbo: 1.0
        case .fluxKleinBase: 4.0
        }
    }

    /// The family of the model in `directory`, by Iris's rules: a Z-Image
    /// pipeline is named in `model_index.json` or has a `cap_feat_dim`
    /// transformer setting; otherwise a model is distilled unless
    /// `model_index.json` exists without `"is_distilled": true`. Iris reads
    /// only the start of each file, and so does this.
    static func detect(in directory: URL) -> IrisModelFamily {
        let index = prefix(of: directory.appending(path: "model_index.json"), bytes: 4_095)
        let transformer = prefix(
            of: directory.appending(components: "transformer", "config.json"), bytes: 8_191)

        if let index, index.contains("ZImagePipeline") || index.contains("Z-Image") {
            return .zImageTurbo
        }
        if let transformer, transformer.contains("\"cap_feat_dim\"") {
            return .zImageTurbo
        }
        guard let index else { return .fluxKlein }
        let distilled =
            index.contains("\"is_distilled\": true") || index.contains("\"is_distilled\":true")
        return distilled ? .fluxKlein : .fluxKleinBase
    }

    private static func prefix(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated struct IrisFluxKleinModel: EngineModel {
    /// Iris models run flow matching with no negative prompt. They attend to
    /// images as references rather than denoising from one, so they declare
    /// input images and no starting image at all. Steps and guidance are pinned
    /// to the family's own values, so the sidebar shows what the pipeline runs.
    static func constraints(for family: IrisModelFamily) -> OptionConstraints {
        OptionConstraints(
            supportsNegativePrompt: false,
            size: .freeform(range: 64...1_792, step: 16),
            steps: .pinned(family.stepCount),
            guidanceScale: .pinned(family.guidanceScale),
            scheduler: .pinned(.discreteFlowScheduler),
            startingImage: .unsupported,
            inputImages: .supported(maxCount: IrisEngine.maxReferenceImages),
            controlNet: .unsupported,
            quality: .unsupported,
            numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
            promptTokenLimit: 512
        )
    }

    static let metadataFields: Set<MetadataField> = [
        .prompt,
        .model,
        .engine,
        .modelKey,
        .size,
        .inputImages,
        .scheduler,
        .seed,
        .steps,
        // Pinned rather than absent, so the value the model ran at is recorded.
        .guidanceScale,
    ]

    /// Fallback when the transformer config cannot be read. Klein's own value; a
    /// wrong head count only misestimates the reference budget, so guessing is
    /// better than refusing to load the model.
    static let defaultAttentionHeadCount = 24

    let url: URL
    let name: String
    /// Read from `transformer/config.json`. Attention memory grows with the square
    /// of the sequence length *times* the head count, so this is what makes the
    /// reference budget a real estimate rather than a guess.
    let attentionHeadCount: Int
    let family: IrisModelFamily

    var id: ModelID { ModelID(engine: .iris, key: ModelID.localKey(for: url)) }
    var tokenizerModelDir: URL? { url.appending(path: "tokenizer") }
    var constraints: OptionConstraints { Self.constraints(for: family) }
    var metadataFields: Set<MetadataField> { Self.metadataFields }

    init?(url: URL, name: String) {
        guard isIrisFluxKleinModelDirectory(url) else { return nil }
        self.url = url
        self.name = name
        self.attentionHeadCount = readAttentionHeadCount(from: url)
        self.family = IrisModelFamily.detect(in: url)
    }
}

nonisolated private func readAttentionHeadCount(from modelURL: URL) -> Int {
    let configURL = modelURL.appending(components: "transformer", "config.json")
    guard
        let data = try? Data(contentsOf: configURL),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return IrisFluxKleinModel.defaultAttentionHeadCount
    }

    if let value = json["num_attention_heads"] as? Int, value > 0 {
        return value
    }

    if let value = json["num_attention_heads"] as? NSNumber, value.intValue > 0 {
        return value.intValue
    }

    return IrisFluxKleinModel.defaultAttentionHeadCount
}

nonisolated private func isIrisFluxKleinModelDirectory(_ url: URL) -> Bool {
    let fm = FileManager.default

    for url in [
        url.appending(components: "text_encoder", "config.json"),
        url.appending(components: "text_encoder", "generation_config.json"),
        url.appending(components: "tokenizer", "added_tokens.json"),
        url.appending(components: "tokenizer", "chat_template.jinja"),
        url.appending(components: "tokenizer", "merges.txt"),
        url.appending(components: "tokenizer", "special_tokens_map.json"),
        url.appending(components: "tokenizer", "tokenizer.json"),
        url.appending(components: "tokenizer", "tokenizer_config.json"),
        url.appending(components: "tokenizer", "vocab.json"),

        url.appending(components: "transformer", "config.json"),
        url.appending(components: "vae", "config.json"),
        url.appending(components: "vae", "diffusion_pytorch_model.safetensors"),
    ] {
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            return false
        }
    }

    if !hasSafetensorWeights(
        in: url.appending(path: "text_encoder"),
        baseName: "model",
        fileManager: fm
    ) {
        return false
    }

    if !hasSafetensorWeights(
        in: url.appending(path: "transformer"),
        baseName: "diffusion_pytorch_model",
        fileManager: fm
    ) {
        return false
    }

    return true
}

nonisolated private func hasSafetensorWeights(
    in directory: URL,
    baseName: String,
    fileManager: FileManager
) -> Bool {
    let plainWeights = directory.appending(path: "\(baseName).safetensors")
    if fileManager.fileExists(atPath: plainWeights.path(percentEncoded: false)) {
        return true
    }

    let index = directory.appending(path: "\(baseName).safetensors.index.json")
    guard fileManager.fileExists(atPath: index.path(percentEncoded: false)) else {
        return false
    }

    guard
        let contents = try? fileManager.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        )
    else {
        return false
    }

    let shardPrefix = "\(baseName)-"
    return contents.contains { name in
        name.hasPrefix(shardPrefix) && name.hasSuffix(".safetensors")
    }
}
