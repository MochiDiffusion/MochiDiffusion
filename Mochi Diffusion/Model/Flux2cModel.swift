//
//  Flux2cModel.swift
//  Mochi Diffusion
//

import Foundation

struct Flux2cModel: MochiModel {
    static let generationCapabilities: GenerationCapabilities = [.startingImage]
    static let metadataFields: Set<MetadataField> = [
        .prompt,
        .model,
        .size,
        .scheduler,
        .seed,
        .steps,
    ]

    let url: URL
    let name: String

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
        guard isFlux2cModelDirectory(url) else { return nil }
        self.url = url
        self.name = name
    }
}

private func isFlux2cModelDirectory(_ url: URL) -> Bool {
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

private func hasSafetensorWeights(
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
