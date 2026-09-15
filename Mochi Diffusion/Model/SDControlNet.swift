//
//  ControlNet.swift
//  Mochi Diffusion
//
//  Created by Stuart Moore on 6/3/23.
//

import Foundation
import os.log

nonisolated private let logger = Logger()

nonisolated struct SDControlNet {
    let name: String
    let url: URL
    let size: CGSize
    let attention: SDModelAttentionType

    init?(url: URL) {
        guard let size = identifyControlNetSize(url),
            let attention = identifyControlNetAttentionType(url)
        else {
            return nil
        }

        self.name = url.deletingPathExtension().lastPathComponent
        self.url = url
        self.size = size
        self.attention = attention
    }
}

nonisolated private func identifyControlNetSize(_ url: URL) -> CGSize? {
    let metadataURL = url.appendingPathComponent("metadata.json")

    guard let jsonData = try? Data(contentsOf: metadataURL) else {
        logger.warning("Could not read ControlNet metadata at '\(metadataURL)'")
        return nil
    }

    guard let jsonArray = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]]
    else {
        logger.warning("Could not parse ControlNet metadata at '\(metadataURL)'")
        return nil
    }

    guard let jsonItem = jsonArray.first else {
        logger.warning("ControlNet metadata is empty at '\(metadataURL)'")
        return nil
    }

    guard let inputSchema = jsonItem["inputSchema"] as? [[String: Any]] else {
        logger.warning("ControlNet metadata has no input schema at '\(metadataURL)'")
        return nil
    }

    guard
        let controlnetCond = inputSchema.first(where: {
            ($0["name"] as? String) == "controlnet_cond"
        })
    else {
        logger.warning("ControlNet metadata has no controlnet_cond input at '\(metadataURL)'")
        return nil
    }

    guard let shapeString = controlnetCond["shape"] as? String else {
        logger.warning("ControlNet metadata has no controlnet_cond shape at '\(metadataURL)'")
        return nil
    }

    guard let size = CoreMLMetadataShape.imageSize(from: shapeString) else {
        logger.warning(
            "Unsupported ControlNet input shape '\(shapeString)' at '\(metadataURL)'"
        )
        return nil
    }
    return size
}

nonisolated private func identifyControlNetAttentionType(_ url: URL) -> SDModelAttentionType? {
    let metadataURL = url.appendingPathComponent("metadata.json")

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
        logger.warning("Failed to parse ControlNet metadata at '\(metadataURL)': \(error)")
        return nil
    }
}
