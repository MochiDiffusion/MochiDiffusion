//
//  IrisFluxKleinModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated struct IrisFluxKleinModel: EngineModel {
    /// FLUX.2 Klein is distilled: four steps on the flow-match scheduler, and
    /// guidance baked into the weights rather than applied at sampling time, so
    /// there is no negative prompt to offer. It attends to images as references
    /// rather than denoising from one, so it declares input images and no starting
    /// image at all.
    static let constraints = OptionConstraints(
        supportsNegativePrompt: false,
        size: .freeform(range: 64...1_792, step: 16),
        steps: .pinned(distilledStepCount),
        guidanceScale: .pinned(distilledGuidanceScale),
        scheduler: .pinned(.discreteFlowScheduler),
        startingImage: .unsupported,
        inputImages: .supported(maxCount: IrisEngine.maxReferenceImages),
        controlNet: .unsupported,
        quality: .unsupported,
        numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
        promptTokenLimit: 512
    )

    static let distilledStepCount = 4

    /// Pinned rather than unsupported, so the sidebar shows the value the pipeline
    /// runs at instead of dropping the row.
    ///
    /// A guidance-distilled model runs no classifier-free guidance at all: Iris
    /// sends Klein down `iris_sample_euler_flux` with no unconditioned pass, and
    /// 1.0 is the scale at which the CFG formula `v_uncond + g * (v_cond -
    /// v_uncond)` reduces to `v_cond`. It is also what Iris itself resolves for a
    /// distilled model.
    static let distilledGuidanceScale = 1.0

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

    var id: ModelID { ModelID(engine: .iris, key: ModelID.localKey(for: url)) }
    var tokenizerModelDir: URL? { url.appending(path: "tokenizer") }
    var constraints: OptionConstraints { Self.constraints }
    var metadataFields: Set<MetadataField> { Self.metadataFields }

    init?(url: URL, name: String) {
        guard isIrisFluxKleinModelDirectory(url) else { return nil }
        self.url = url
        self.name = name
        self.attentionHeadCount = readAttentionHeadCount(from: url)
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
