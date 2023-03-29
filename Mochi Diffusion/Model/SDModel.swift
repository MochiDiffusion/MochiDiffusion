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

struct SDModel: Identifiable, Hashable {
    let url: URL
    let name: String
    let attention: SDModelAttentionType

    var id: URL { url }

    init?(url: URL, name: String) {
        guard let attention = identifyAttentionType(url) else {
            return nil
        }

        self.url = url
        self.name = name
        self.attention = attention
    }
}

private func identifyAttentionType(_ url: URL) -> SDModelAttentionType? {
    let unetMetadataURL = url.appending(components: "Unet.mlmodelc", "metadata.json")

    struct ModelMetadata: Decodable {
        let mlProgramOperationTypeHistogram: [String: Int]
    }

    do {
        let jsonData = try Data(contentsOf: unetMetadataURL)
        let metadatas = try JSONDecoder().decode([ModelMetadata].self, from: jsonData)

        guard metadatas.count == 1 else {
            return nil
        }

        return metadatas[0].mlProgramOperationTypeHistogram["Ios16.einsum"] != nil ? .splitEinsum : .original
    } catch {
        logger.warning("Failed to parse model metadata at '\(unetMetadataURL)': \(error)")
        return nil
    }
}
