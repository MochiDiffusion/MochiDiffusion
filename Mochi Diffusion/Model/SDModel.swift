//
//  SDModel.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Foundation
import os.log

private let logger = Logger()

struct SDModel: MochiModel {
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

    var id: URL { url }
    var promptTokenLimit: Int? { 75 }
    var tokenizerModelDir: URL? { url }
    var config: MochiModelConfig {
        MochiModelConfig(
            generationCapabilities: [
                .negativePrompt,
                .startingImage,
                .strength,
                .stepCount,
                .guidanceScale,
                .scheduler,
                .controlNet,
            ],
            metadataFields: [
                .prompt,
                .negativePrompt,
                .model,
                .size,
                .scheduler,
                .mlComputeUnit,
                .seed,
                .steps,
                .guidanceScale,
            ]
        )
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

extension SDModel: Hashable {
    static func == (lhs: SDModel, rhs: SDModel) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private func identifyAttentionType(_ url: URL) -> SDModelAttentionType? {
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

private func identifyIfXL(_ url: URL) -> Bool {
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

private func identifyIfSD3(_ url: URL) -> Bool {
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

private func unetMetadataURL(from url: URL) -> URL? {
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

private func identifyInputSize(_ url: URL) -> CGSize? {
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
