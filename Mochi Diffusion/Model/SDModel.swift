//
//  SDModel.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Foundation
import os.log

nonisolated private let logger = Logger()

/// Reads the fixed NCHW image shape emitted in compiled Core ML metadata.
///
/// Requiring every dimension to parse avoids shifting the height and width when
/// metadata contains an unexpected token. Core ML image inputs used here have
/// exactly four positive dimensions: batch, channels, height and width.
nonisolated enum CoreMLMetadataShape {
    static func imageSize(from shape: String) -> CGSize? {
        let shape = shape.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shape.first == "[", shape.last == "]" else { return nil }

        let components = shape.dropFirst().dropLast().split(
            separator: ",",
            omittingEmptySubsequences: false
        )
        guard components.count == 4 else { return nil }

        let dimensions = components.compactMap {
            Int(String($0).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard dimensions.count == components.count, dimensions.allSatisfy({ $0 > 0 }) else {
            return nil
        }

        return CGSize(width: dimensions[3], height: dimensions[2])
    }
}

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
            // The step slider keeps a typed value above its span, so the
            // constraint accepts it too.
            steps: .range(1...50, step: 1, acceptsBeyondUpperBound: true),
            // Matches the slider's bounds, so persisted values are not clamped.
            guidanceScale: .range(1...20, step: nil),
            scheduler: .oneOf(Scheduler.allCases),
            startingImage: .supported(strength: .range(0...1, step: nil)),
            inputImages: .unsupported,
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

        let size: CGSize?
        switch identifyInputSize(url) {
        case .freeform:
            size = nil
        case .fixed(let fixedSize):
            size = fixedSize
        case .invalid:
            return nil
        }

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

nonisolated private enum InputSizeIdentification {
    case freeform
    case fixed(CGSize)
    case invalid
}

nonisolated private func identifyInputSize(_ url: URL) -> InputSizeIdentification {
    let encoderMetadataURL = url.appending(path: "VAEEncoder.mlmodelc").appending(
        path: "metadata.json")
    guard FileManager.default.fileExists(atPath: encoderMetadataURL.path(percentEncoded: false))
    else {
        return .freeform
    }

    do {
        let jsonData = try Data(contentsOf: encoderMetadataURL)
        guard
            let jsonArray = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
            let jsonItem = jsonArray.first,
            let inputSchema = jsonItem["inputSchema"] as? [[String: Any]],
            let encoderInput = inputSchema.first,
            let shapeString = encoderInput["shape"] as? String
        else {
            logger.warning("Unsupported VAE encoder metadata at '\(encoderMetadataURL)'")
            return .invalid
        }

        guard let size = CoreMLMetadataShape.imageSize(from: shapeString) else {
            logger.warning(
                "Unsupported VAE encoder input shape '\(shapeString)' at '\(encoderMetadataURL)'"
            )
            return .invalid
        }
        return .fixed(size)
    } catch {
        logger.warning("Failed to parse model metadata at '\(encoderMetadataURL)': \(error)")
        return .invalid
    }
}
