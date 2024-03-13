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
    let controltype: ControlType?
    let allowsVariableSize: Bool
    private let vaeAllowsVariableSize: Bool

    var id: URL { url }

    init?(url: URL, name: String, controlNet: [SDControlNet]) {
        guard
            let attention = identifyAttentionType(url),
            let allowsVariableSize = identifyAllowsVariableSize(url),
            let vaeAllowsVariableSize = identifyVaeAllowsVariableSize(url),
            let size = identifyInputSize(url)
        else {
            return nil
        }

        let isXL = identifyIfXL(url)
        let controltype = identifyControlNetType(url)

        self.url = url
        self.name = name
        self.attention = attention
        self.controlNet = controlNet.filter { $0.size == size && $0.attention == attention && $0.controltype == controltype ?? .all }.map { $0.name }
        self.isXL = isXL
        self.inputSize = size
        self.controltype = controltype
        self.allowsVariableSize = allowsVariableSize
        self.vaeAllowsVariableSize = vaeAllowsVariableSize
    }
}

extension SDModel: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension SDModel {
    /// replace VAEEncoder.mlmodelc/coremldata.bin with en-coremldata.bin
    /// replace VAEDecoder.mlmodelc/coremldata.bin with de-coremldata.bin
    func resizeableCopy(target: URL, controlNet: [SDControlNet] = []) -> SDModel? {
        guard allowsVariableSize && !vaeAllowsVariableSize else {
            return nil
        }
        do {
            if !FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) {
                try recursiveHardLink(source: url, target: target)

                let encoderBinURL = target.appending(components: "VAEEncoder.mlmodelc", "coremldata.bin")
                try? FileManager.default.removeItem(at: encoderBinURL)
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "en-coremldata", withExtension: "bin")!, to: encoderBinURL)

                let decoderBinURL = target.appending(components: "VAEDecoder.mlmodelc", "coremldata.bin")
                try? FileManager.default.removeItem(at: decoderBinURL)
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "de-coremldata", withExtension: "bin")!, to: decoderBinURL)

                let encoderMilURL = target.appending(components: "VAEEncoder.mlmodelc", "model.mil")
                let encoderMilBakURL = target.appending(components: "VAEEncoder.mlmodelc", "model.mil.bak")
                try? FileManager.default.removeItem(at: encoderMilURL)
                try? FileManager.default.removeItem(at: encoderMilBakURL)
                try FileManager.default.copyItem(at: url.appending(components: "VAEEncoder.mlmodelc", "model.mil"), to: encoderMilBakURL)

                let decoderMilURL = target.appending(components: "VAEDecoder.mlmodelc", "model.mil")
                let decoderMilBakURL = target.appending(components: "VAEDecoder.mlmodelc", "model.mil.bak")
                try? FileManager.default.removeItem(at: decoderMilURL)
                try? FileManager.default.removeItem(at: decoderMilBakURL)
                try FileManager.default.copyItem(at: url.appending(components: "VAEDecoder.mlmodelc", "model.mil"), to: decoderMilBakURL)

                let encoderMetadataURL = target.appending(components: "VAEEncoder.mlmodelc", "metadata.json")
                try? FileManager.default.removeItem(at: encoderMetadataURL)
                try FileManager.default.copyItem(at: url.appending(components: "VAEEncoder.mlmodelc", "metadata.json"), to: encoderMetadataURL)
            }

            return SDModel(url: target, name: name, controlNet: controlNet)
        } catch {
            print("ERROR: Unable to create resizeable copy of SDModel \(name) \(error)")
            return nil
        }
    }

    /// overwrite shape data in VAEEncoder.mlmodelc/model.mil
    func modifyEncoderMil(width: Int, height: Int) {
        let milURL = url.appending(components: "VAEEncoder.mlmodelc", "model.mil")
        let milBakUrl = url.appending(components: "VAEEncoder.mlmodelc", "model.mil.bak")
        do {
            var fileContent = try String(contentsOf: milBakUrl, encoding: .utf8)
            if isXL {
                fileContent = fileContent.replacingOccurrences(of: "[1, 8, 128, 128]", with: "[1, 8, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 16384, 512]", with: "[1, 1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 16384, 16384]", with: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 16384, 1, 512]", with: "[1, \(height / 8 * width / 8), 1, 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 16384, 512]", with: "[1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 16384]", with: "[1, 512, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 16384]", with: "[1, 32, 16, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 128, 128]", with: "[1, 32, 16, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 128, 128]", with: "[1, 512, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 257, 257]", with: "[1, 512, \(height / 4 + 1), \(width / 4 + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 256, 256]", with: "[1, 32, 16, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 256, 256]", with: "[1, 512, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 256, 256]", with: "[1, 32, 8, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 256, 256]", with: "[1, 256, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 513, 513]", with: "[1, 256, \(height / 2 + 1), \(width / 2 + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 512, 512]", with: "[1, 32, 8, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 512, 512]", with: "[1, 256, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 512, 512]", with: "[1, 32, 4, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 512, 512]", with: "[1, 128, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 1025, 1025]", with: "[1, 128, \(height + 1), \(width + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 1024, 1024]", with: "[1, 128, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 1024, 1024]", with: "[1, 32, 4, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 3, 1024, 1024]", with: "[1, 3, \(height), \(width)]")
            } else {
                fileContent = fileContent.replacingOccurrences(of: "[1, 8, 64, 64]", with: "[1, 8, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 4096, 512]", with: "[1, 1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 4096, 4096]", with: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 4096, 1, 512]", with: "[1, \(height / 8 * width / 8), 1, 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 4096, 512]", with: "[1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 4096]", with: "[1, 512, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 4096]", with: "[1, 32, 16, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 64, 64]", with: "[1, 32, 16, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 64, 64]", with: "[1, 512, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 129, 129]", with: "[1, 512, \(height / 4 + 1), \(width / 4 + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 128, 128]", with: "[1, 32, 16, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 128, 128]", with: "[1, 512, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 128, 128]", with: "[1, 32, 8, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 128, 128]", with: "[1, 256, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 257, 257]", with: "[1, 256, \(height / 2 + 1), \(width / 2 + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 256, 256]", with: "[1, 32, 8, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 256, 256]", with: "[1, 256, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 256, 256]", with: "[1, 32, 4, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 256, 256]", with: "[1, 128, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 513, 513]", with: "[1, 128, \(height + 1), \(width + 1)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 512, 512]", with: "[1, 128, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 512, 512]", with: "[1, 32, 4, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 3, 512, 512]", with: "[1, 3, \(height), \(width)]")
            }
            try fileContent.write(to: milURL, atomically: false, encoding: .utf8)
        } catch {
            print("Error: Unable to modify \(milURL.path(percentEncoded: false))")
        }
    }

    /// overwrite shape data in VAEDecoder.mlmodelc/model.mil
    func modifyDecoderMil(width: Int, height: Int) {
        let milURL = url.appending(components: "VAEDecoder.mlmodelc", "model.mil")
        let milBakURL = url.appending(components: "VAEDecoder.mlmodelc", "model.mil.bak")
        do {
            var fileContent = try String(contentsOf: milBakURL, encoding: .utf8)
            if isXL {
                fileContent = fileContent.replacingOccurrences(of: "[1, 4, 128, 128]", with: "[1, 4, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 128, 128]", with: "[1, 512, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 128, 128]", with: "[1, 32, 16, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 16384]", with: "[1, 32, 16, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 16384]", with: "[1, 512, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 16384, 512]", with: "[1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 16384, 1, 512]", with: "[1, \(height / 8 * width / 8), 1, 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 16384, 512]", with: "[1, 1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 16384, 16384]", with: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 256, 256]", with: "[1, 512, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 256, 256]", with: "[1, 32, 16, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 512, 512]", with: "[1, 512, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 512, 512]", with: "[1, 32, 16, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 512, 512]", with: "[1, 256, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 512, 512]", with: "[1, 32, 8, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 1024, 1024]", with: "[1, 256, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 1024, 1024]", with: "[1, 32, 8, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 1024, 1024]", with: "[1, 128, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 1024, 1024]", with: "[1, 32, 4, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 3, 1024, 1024]", with: "[1, 3, \(height), \(width)]")
            } else {
                fileContent = fileContent.replacingOccurrences(of: "[1, 4, 64, 64]", with: "[1, 4, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 64, 64]", with: "[1, 512, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 64, 64]", with: "[1, 32, 16, \(height / 8), \(width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 4096]", with: "[1, 32, 16, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 4096]", with: "[1, 512, \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 4096, 512]", with: "[1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 4096, 1, 512]", with: "[1, \(height / 8 * width / 8), 1, 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 4096, 512]", with: "[1, 1, \(height / 8 * width / 8), 512]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 1, 4096, 4096]", with: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 128, 128]", with: "[1, 512, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 128, 128]", with: "[1, 32, 16, \(height / 4), \(width / 4)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 512, 256, 256]", with: "[1, 512, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 16, 256, 256]", with: "[1, 32, 16, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 256, 256]", with: "[1, 256, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 256, 256]", with: "[1, 32, 8, \(height / 2), \(width / 2)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 256, 512, 512]", with: "[1, 256, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 8, 512, 512]", with: "[1, 32, 8, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 128, 512, 512]", with: "[1, 128, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 32, 4, 512, 512]", with: "[1, 32, 4, \(height), \(width)]")
                fileContent = fileContent.replacingOccurrences(of: "[1, 3, 512, 512]", with: "[1, 3, \(height), \(width)]")
            }
            try fileContent.write(to: milURL, atomically: false, encoding: .utf8)
        } catch {
            print("Error: Unable to modify \(milURL.path(percentEncoded: false))")
        }
    }

    /// Writes desired size value to inputSchema["shape"] of VAEEncoder.mlmodelc/metadata.json
    public func modifyInputSize(width: Int, height: Int) {
        guard allowsVariableSize && !vaeAllowsVariableSize else {
            print("ERROR: model \(name) cannot modify input size")
            return
        }

        let encoderMetadataURL = url.appendingPathComponent("VAEEncoder.mlmodelc").appendingPathComponent("metadata.json")
        guard
            let jsonData = try? Data(contentsOf: encoderMetadataURL),
            var jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
            var jsonItem = jsonArray.first,
            var inputSchema = jsonItem["inputSchema"] as? [[String: Any]],
            var controlnetCond = inputSchema.first,
            var shapeString = controlnetCond["shape"] as? String
        else {
            return
        }

        var shapeIntArray = shapeString.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .components(separatedBy: ", ")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        shapeIntArray[3] = width
        shapeIntArray[2] = height
        shapeString = "[\(shapeIntArray.map { String($0) }.joined(separator: ", "))]"

        controlnetCond["shape"] = shapeString
        inputSchema[0] = controlnetCond
        jsonItem["inputSchema"] = inputSchema
        jsonArray[0] = jsonItem

        if let updatedJsonData = try? JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted) {
            try? updatedJsonData.write(to: encoderMetadataURL)
            print("update metadata.")
        } else {
            print("Failed to update metadata.")
        }
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
        if shapeString == "[]"{
            return nil
        }
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
    } else if inputSchema.first(where: { ($0["name"] as? String) == "adapter_res_samples_00" }) != nil {
        return .t2IAdapter
    } else {
        return .controlNet
    }
}

// swiftlint:disable discouraged_optional_boolean
private func identifyAllowsVariableSize(_ url: URL) -> Bool? {
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

    return inputSchema.first { ($0["hasShapeFlexibility"] as? String) == "1" } != nil
}

private func identifyVaeAllowsVariableSize(_ url: URL) -> Bool? {
    let metadataURL = url.appending(path: "VAEDecoder.mlmodelc").appending(path: "metadata.json")

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

    return inputSchema.first { ($0["hasShapeFlexibility"] as? String) == "1" } != nil
}
// swiftlint:enable discouraged_optional_boolean
