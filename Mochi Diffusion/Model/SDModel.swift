//
//  SDModel.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import Foundation
import os.log

private let logger = Logger()

struct SDModel: Identifiable {
    let url: URL
    let name: String
    let attention: SDModelAttentionType
    let controlNet: [String]
    let isXL: Bool
    var inputSize: CGSize?
    var controltype: ControlType?

    var id: URL { url }

    init?(url: URL, name: String, controlNet: [SDControlNet]) {
        guard let attention = identifyAttentionType(url) else {
            return nil
        }

        let isXL = identifyIfXL(url)
        let size = identifyInputSize(url)
        let controltype = identifyControlNetType(url)

        self.url = url
        self.name = name
        self.attention = attention
        if let size = size {
            self.controlNet = controlNet.filter { $0.size == size && $0.attention == attention && $0.controltype == controltype ?? .all}.map { $0.name }
        } else {
            self.controlNet = []
        }
        self.isXL = isXL
        self.inputSize = size
        self.controltype = controltype
    }
}

extension SDModel: Hashable {
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

        return metadatas[0].mlProgramOperationTypeHistogram["Ios16.einsum"] != nil ? .splitEinsum : .original
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

private func unetMetadataURL(from url: URL) -> URL? {
    let potentialMetadataURLs = [
        url.appending(components: "Unet.mlmodelc", "metadata.json"),
        url.appending(components: "UnetChunk1.mlmodelc", "metadata.json")
    ]

    return potentialMetadataURLs.first {
        FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
}

private func identifyInputSize(_ url: URL) -> CGSize? {
    let encoderMetadataURL = url.appending(path: "VAEDecoder.mlmodelc").appending(path: "metadata.json")
    if let jsonData = try? Data(contentsOf: encoderMetadataURL),
        let jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
        let jsonItem = jsonArray.first,
        let inputSchema = jsonItem["outputSchema"] as? [[String: Any]],
        let controlnetCond = inputSchema.first,
        let shapeString = controlnetCond["shape"] as? String {
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

private func identifyControlNetType(_ url: URL) -> ControlType? {
    let metadataURL = url.appending(path: "Unet.mlmodelc").appending(path: "metadata.json")

    guard let jsonData = try? Data(contentsOf: metadataURL) else {
        print("Error: Could not read data from \(metadataURL)")
        return nil
    }

    guard let jsonArray = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]] else {
        print("Error: Could not parse JSON data")
        return nil
    }

    guard let jsonItem = jsonArray.first else {
        print("Error: JSON array is empty")
        return nil
    }

    guard let inputSchema = jsonItem["inputSchema"] as? [[String: Any]] else {
        print("Error: Missing 'inputSchema' in JSON")
        return nil
    }

    if inputSchema.first(where: { ($0["name"] as? String) == "adapter_res_samples_00" }) != nil && inputSchema.first(where: { ($0["name"] as? String) == "down_block_res_samples_00" }) != nil {
        return .all
    }else if inputSchema.first(where: { ($0["name"] as? String) == "adapter_res_samples_00" }) != nil {
        return .T2IAdapter
    }else{
        return .ControlNet
    }
}
