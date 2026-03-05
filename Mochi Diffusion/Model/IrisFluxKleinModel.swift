//
//  IrisFluxKleinModel.swift
//  Mochi Diffusion
//

import Foundation

nonisolated struct IrisFluxKleinModel: MochiModel {
    static let defaultAttentionHeadCount = 24
    static let generationCapabilities: GenerationCapabilities = [.inputImages]
    static let metadataFields: Set<MetadataField> = [
        .prompt,
        .model,
        .size,
        .inputImages,
        .scheduler,
        .seed,
        .steps,
    ]

    let url: URL
    let name: String
    let attentionHeadCount: Int

    var id: URL { url }
    var promptTokenLimit: Int? { 512 }
    var tokenizerModelDir: URL? { url.appending(path: "tokenizer") }
    var config: MochiModelConfig {
        MochiModelConfig(
            generationCapabilities: Self.generationCapabilities,
            metadataFields: Self.metadataFields
        )
    }

    init?(url: URL, name: String) {
        guard isIrisFluxKleinModelDirectory(url) else { return nil }
        self.url = url
        self.name = name
        self.attentionHeadCount = readAttentionHeadCount(from: url)
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

    if let value = json["num_attention_heads"] as? NSNumber,
        value.intValue > 0
    {
        return value.intValue
    }

    return IrisFluxKleinModel.defaultAttentionHeadCount
}
