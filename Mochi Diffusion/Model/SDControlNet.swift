//
//  ControlNet.swift
//  Mochi Diffusion
//
//  Created by Stuart Moore on 6/3/23.
//

import CoreGraphics
import Foundation

struct SDControlNet {
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

private func identifyControlNetSize(_ url: URL) -> CGSize? {
    let metadataURL = url.appendingPathComponent("metadata.json")

    guard let jsonData = try? Data(contentsOf: metadataURL) else {
        print("Error: Could not read data from \(metadataURL)")
        return nil
    }

    guard let jsonArray = (try? JSONSerialization.jsonObject(with: jsonData)) as? [[String: Any]]
    else {
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

    guard
        let controlnetCond = inputSchema.first(where: {
            ($0["name"] as? String) == "controlnet_cond"
        })
    else {
        print("Error: 'controlnet_cond' not found in 'inputSchema'")
        return nil
    }

    guard let shapeString = controlnetCond["shape"] as? String else {
        print("Error: 'shape' not found in 'controlnet_cond'")
        return nil
    }

    let shapeIntArray =
        shapeString
        .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        .components(separatedBy: ", ")
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

    guard shapeIntArray.count >= 4 else {
        print("Error: 'shape' does not have enough elements")
        return nil
    }

    let width = shapeIntArray[3]
    let height = shapeIntArray[2]

    return CGSize(width: width, height: height)
}

private func identifyControlNetAttentionType(_ url: URL) -> SDModelAttentionType? {
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
        print("Failed to parse model metadata at '\(metadataURL)': \(error)")
        return nil
    }
}
