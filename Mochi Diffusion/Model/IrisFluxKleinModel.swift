//
//  IrisFluxKleinModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated struct IrisFluxKleinModel: EngineModel {
    /// FLUX.2 Klein is distilled: four steps on the flow-match scheduler, and no
    /// classifier-free guidance, so there is no negative prompt or guidance scale
    /// to offer. It accepts a starting image but treats it as an input image
    /// rather than a denoising origin, so strength has no meaning.
    static let constraints = OptionConstraints(
        supportsNegativePrompt: false,
        size: .freeform(range: 64...1_792, step: 16),
        steps: .pinned(distilledStepCount),
        guidanceScale: .unsupported,
        scheduler: .pinned(.discreteFlowScheduler),
        startingImage: .supported(strength: .unsupported),
        controlNet: .unsupported,
        quality: .unsupported,
        numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
        promptTokenLimit: 512
    )

    static let distilledStepCount = 4

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
    ]

    let url: URL
    let name: String

    var id: ModelID { ModelID(engine: .iris, key: ModelID.localKey(for: url)) }
    var tokenizerModelDir: URL? { url.appending(path: "tokenizer") }
    var constraints: OptionConstraints { Self.constraints }
    var metadataFields: Set<MetadataField> { Self.metadataFields }

    init?(url: URL, name: String) {
        guard isIrisFluxKleinModelDirectory(url) else { return nil }
        self.url = url
        self.name = name
    }
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
