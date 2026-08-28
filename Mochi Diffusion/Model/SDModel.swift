//
//  SDModel.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Foundation
import os.log

nonisolated private let logger = Logger()

nonisolated struct SDModel: EngineModel {
    enum ModelType: Sendable {
        case sdxl
        case sd3
        case sd15
    }
    let type: ModelType
    let url: URL
    let name: String
    let attention: SDModelAttentionType
    let controlNet: [String]
    let inputSize: CGSize?

    var id: ModelID { ModelID(engine: .coreMLStableDiffusion, key: ModelID.localKey(for: url)) }
    var tokenizerModelDir: URL? { url }

    /// Per model, not per engine. A converted Core ML model has whatever
    /// resolution it was converted at, and only ControlNets converted to the same
    /// size and attention type can be used with it — which is why `inputSize` and
    /// `controlNet` decide two of these.
    var constraints: OptionConstraints {
        OptionConstraints(
            supportsNegativePrompt: true,
            size: inputSize.map { .pinned([$0]) }
                ?? .freeform(range: 64...1_792, step: 16),
            // The released sliders pass `strictUpperBound: false`, so a typed
            // value above the span is kept. Clamping here would show one number
            // and generate another.
            steps: .range(1...50, step: 1, acceptsBeyondUpperBound: true),
            // Bounds match the released sliders exactly. Tightening them would
            // clamp values users already have persisted.
            guidanceScale: .range(1...20, step: nil),
            scheduler: .oneOf(Scheduler.allCases),
            startingImage: .supported(strength: .range(0...1, step: nil)),
            controlNet: controlNet.isEmpty ? .unsupported : .supported(names: controlNet),
            quality: .unsupported,
            numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
            promptTokenLimit: 75
        )
    }

    var metadataFields: Set<MetadataField> {
        [
            .prompt,
            .negativePrompt,
            .model,
            .engine,
            .modelKey,
            .size,
            .scheduler,
            .mlComputeUnit,
            .startingImage,
            .controlNetImage,
            .seed,
            .steps,
            .guidanceScale,
        ]
    }

    init?(url: URL, name: String, controlNet: [SDControlNet]) {
        guard let attention = identifyAttentionType(url) else {
            return nil
        }

        if identifyIfXL(url) {
            type = .sdxl
        } else if identifyIfSD3(url) {
            type = .sd3
        } else {
            type = .sd15
        }

        let size = identifyInputSize(url)

        self.url = url
        self.name = name
        self.attention = attention
        if let size = size {
            self.controlNet = controlNet.filter { $0.size == size && $0.attention == attention }.map
            { $0.name }
        } else {
            self.controlNet = []
        }
        self.inputSize = size
    }
}

nonisolated extension SDModel: Hashable {
    static func == (lhs: SDModel, rhs: SDModel) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated private func identifyAttentionType(_ url: URL) -> SDModelAttentionType? {
    guard let metadataURL = unetMetadataURL(from: url) else {
        logger.warning("No model metadata found at '\(url)'")
        return nil
    }

    struct ModelMetadata: Decodable {
        let mlProgramOperationTypeHistogram: [String: Int]
    }

    do {
        let jsonData = try Data(contentsOf: metadataURL)
        let metadatas = try JSONDecoder().decode([ModelMetadata].self, from: jsonData)

        guard metadatas.count == 1 else {
            return nil
        }

        return metadatas[0].mlProgramOperationTypeHistogram["Ios16.einsum"] != nil
            ? .splitEinsum : .original
    } catch {
        logger.warning("Failed to parse model metadata at '\(metadataURL)': \(error)")
        return nil
    }
}

nonisolated private func identifyIfXL(_ url: URL) -> Bool {
    guard let metadataURL = unetMetadataURL(from: url) else {
        logger.warning("No model metadata found at '\(url)'")
        return false
    }

    struct ModelMetadata: Decodable {
        let inputSchema: [[String: String]]
    }

    do {
        let jsonData = try Data(contentsOf: metadataURL)
        let metadatas = try JSONDecoder().decode([ModelMetadata].self, from: jsonData)

        guard metadatas.count == 1 else {
            return false
        }

        // XL models have 5 inputs total (added: time_ids and text_embeds)
        let inputNames = metadatas[0].inputSchema.compactMap { $0["name"] }
        return inputNames.contains("time_ids") && inputNames.contains("text_embeds")
    } catch {
        logger.warning("Failed to parse model metadata at '\(metadataURL)': \(error)")
        return false
    }
}

nonisolated private func identifyIfSD3(_ url: URL) -> Bool {
    guard let metadataURL = unetMetadataURL(from: url) else {
        logger.warning("No model metadata found at '\(url)'")
        return false
    }

    struct ModelMetadata: Decodable {
        let inputSchema: [[String: String]]
    }

    do {
        let jsonData = try Data(contentsOf: metadataURL)
        let metadatas = try JSONDecoder().decode([ModelMetadata].self, from: jsonData)

        guard metadatas.count == 1 else {
            return false
        }

        // SD3 models have 4 inputs with one named "latent_image_embeddings"
        let inputNames = metadatas[0].inputSchema.compactMap { $0["name"] }
        return inputNames.contains("latent_image_embeddings")
    } catch {
        logger.warning("Failed to parse model metadata at '\(metadataURL)': \(error)")
        return false
    }
}

nonisolated private func unetMetadataURL(from url: URL) -> URL? {
    let potentialMetadataURLs = [
        url.appending(components: "Unet.mlmodelc", "metadata.json"),
        url.appending(components: "UnetChunk1.mlmodelc", "metadata.json"),
        url.appending(components: "ControlledUnet.mlmodelc", "metadata.json"),
        url.appending(components: "MultiModalDiffusionTransformer.mlmodelc", "metadata.json"),
    ]

    return potentialMetadataURLs.first {
        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
}

nonisolated private func identifyInputSize(_ url: URL) -> CGSize? {
    let encoderMetadataURL = url.appending(path: "VAEEncoder.mlmodelc").appending(
        path: "metadata.json")
    if let jsonData = try? Data(contentsOf: encoderMetadataURL),
        let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
        let jsonItem = jsonArray.first,
        let inputSchema = jsonItem["inputSchema"] as? [[String: Any]],
        let controlnetCond = inputSchema.first,
        let shapeString = controlnetCond["shape"] as? String
    {
        let shapeIntArray = shapeString.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ", ")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let width = shapeIntArray[3]
        let height = shapeIntArray[2]
        return CGSize(width: width, height: height)
    } else {
        return nil
    }
}
