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
    var allowsVariableSize: Bool

    var id: URL { url }

    init?(url: URL, name: String, controlNet: [SDControlNet]) {
        guard 
            let attention = identifyAttentionType(url),
            let allowsVariableSize = identifyAllowsVariableSize(url),
            let size = identifyInputSize(url)
        else {
            return nil
        }

        let isXL = identifyIfXL(url)
        let controltype = identifyControlNetType(url)

        self.url = url
        self.name = name
        self.attention = attention
        self.controlNet = controlNet.filter { $0.size == size && $0.attention == attention && $0.controltype == controltype ?? .all}.map { $0.name }
        self.isXL = isXL
        self.inputSize = size
        self.controltype = controltype
        self.allowsVariableSize = allowsVariableSize
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
    }else if inputSchema.first(where: { ($0["name"] as? String) == "adapter_res_samples_00" }) != nil {
        return .T2IAdapter
    }else{
        return .ControlNet
    }
}

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

    if inputSchema.first(where: { ($0["hasShapeFlexibility"] as? String) == "1" }) != nil {
        return true
    }else{
        return false
    }
}

public func vaeAllowsVariableSize(_ url: URL) -> Bool? {
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

    if inputSchema.first(where: { ($0["hasShapeFlexibility"] as? String) == "1" }) != nil {
        return true
    }else{
        return false
    }
}

func hackVAE(model: SDModel) async throws {
    let resourcePath = model.url.path(percentEncoded: false)
    
    func updateModelFiles(modelType: String, modelName: String, transformClosure: (String) async throws -> Void) async throws {
        let milPath = "\(resourcePath)/\(modelName).mlmodelc/model.mil"
        let milBakPath = "\(milPath).bak"
        let binPath = "\(resourcePath)/\(modelName).mlmodelc/coremldata.bin"
        let binBakPath = "\(binPath).bak"
        
        if FileManager.default.fileExists(atPath: milBakPath) {
            try FileManager.default.removeItem(atPath: milPath)
            try FileManager.default.copyItem(atPath: milBakPath, toPath: milPath)
            try FileManager.default.removeItem(atPath: binPath)
            try FileManager.default.copyItem(at: Bundle.main.url(forResource: "\(modelType)-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: binPath))
            try await transformClosure(milPath)
        } else {
            try FileManager.default.copyItem(atPath: milPath, toPath: milBakPath)
            try FileManager.default.copyItem(atPath: binPath, toPath: binBakPath)
            try FileManager.default.removeItem(atPath: binPath)
            try FileManager.default.copyItem(at: Bundle.main.url(forResource: "\(modelType)-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: binPath))
            try await transformClosure(milPath)
        }
    }
    
    let transformClosure: (String, (String, Int, Int) async throws -> Void) async throws -> Void = { modelPath, function in
        try await function(modelPath, ImageController.shared.height, ImageController.shared.width)
    }
    
    if model.isXL {
        try await updateModelFiles(modelType: "de", modelName: "VAEDecoder") { vaedecoderMIL in
            return try await transformClosure(vaedecoderMIL, vaeDeSDXL)
        }
        try await updateModelFiles(modelType: "en", modelName: "VAEEncoder") { vaeencoderMIL in
            return try await transformClosure(vaeencoderMIL, vaeEnSDXL)
        }
    } else {
        try await updateModelFiles(modelType: "de", modelName: "VAEDecoder") { vaedecoderMIL in
            return try await transformClosure(vaedecoderMIL, vaeDeSD)
        }
        try await updateModelFiles(modelType: "en", modelName: "VAEEncoder") { vaeencoderMIL in
            return try await transformClosure(vaeencoderMIL, vaeEnSD)
        }
    }
}


private func modifyMILFile(path: String, oldDimensions: String, newDimensions: String) {
    do {
        let fileContent = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let modifiedContent = fileContent.replacingOccurrences(of: oldDimensions, with: newDimensions)
        try modifiedContent.write(to: URL(fileURLWithPath: path),atomically: false, encoding: .utf8)
    } catch {
        print("Error modifying MIL file: \(error)")
    }
}

public func modifyInputSize(_ url: URL, height: Int, width: Int) {
    let encoderMetadataURL = url.appendingPathComponent("VAEEncoder.mlmodelc").appendingPathComponent("metadata.json")
    guard let jsonData = try? Data(contentsOf: encoderMetadataURL),
          var jsonArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]],
          var jsonItem = jsonArray.first,
          var inputSchema = jsonItem["inputSchema"] as? [[String: Any]],
          var controlnetCond = inputSchema.first,
          var shapeString = controlnetCond["shape"] as? String else {
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

private func vaeDeSDXL(vaeMIL: String, height: Int, width: Int) {
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4, 128, 128]", newDimensions: "[1, 4, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 128, 128]", newDimensions: "[1, 512, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 128, 128]", newDimensions: "[1, 32, 16, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 16384]", newDimensions: "[1, 32, 16, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 16384]", newDimensions: "[1, 512, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 16384, 512]", newDimensions: "[1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 16384, 1, 512]", newDimensions: "[1, \(height / 8 * width / 8), 1, 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 16384, 512]", newDimensions: "[1, 1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 16384, 16384]", newDimensions: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 256, 256]", newDimensions: "[1, 512, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 256, 256]", newDimensions: "[1, 32, 16, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 512, 512]", newDimensions: "[1, 512, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 512, 512]", newDimensions: "[1, 32, 16, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 512, 512]", newDimensions: "[1, 256, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 512, 512]", newDimensions: "[1, 32, 8, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 1024, 1024]", newDimensions: "[1, 256, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 1024, 1024]", newDimensions: "[1, 32, 8, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 1024, 1024]", newDimensions: "[1, 128, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 1024, 1024]", newDimensions: "[1, 32, 4, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 3, 1024, 1024]", newDimensions: "[1, 3, \(height), \(width)]")
}

private func vaeEnSDXL(vaeMIL: String, height: Int, width: Int) {
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 8, 128, 128]", newDimensions: "[1, 8, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 16384, 512]", newDimensions: "[1, 1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 16384, 16384]", newDimensions: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 16384, 1, 512]", newDimensions: "[1, \(height / 8 * width / 8), 1, 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 16384, 512]", newDimensions: "[1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 16384]", newDimensions: "[1, 512, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 16384]", newDimensions: "[1, 32, 16, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 128, 128]", newDimensions: "[1, 32, 16, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 128, 128]", newDimensions: "[1, 512, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 257, 257]", newDimensions: "[1, 512, \(height / 4 + 1), \(width / 4 + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 256, 256]", newDimensions: "[1, 32, 16, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 256, 256]", newDimensions: "[1, 512, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 256, 256]", newDimensions: "[1, 32, 8, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 256, 256]", newDimensions: "[1, 256, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 513, 513]", newDimensions: "[1, 256, \(height / 2 + 1), \(width / 2 + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 512, 512]", newDimensions: "[1, 32, 8, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 512, 512]", newDimensions: "[1, 256, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 512, 512]", newDimensions: "[1, 32, 4, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 512, 512]", newDimensions: "[1, 128, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 1025, 1025]", newDimensions: "[1, 128, \(height + 1), \(width + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 1024, 1024]", newDimensions: "[1, 128, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 1024, 1024]", newDimensions: "[1, 32, 4, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 3, 1024, 1024]", newDimensions: "[1, 3, \(height), \(width)]")
}

private func vaeDeSD(vaeMIL: String, height: Int, width: Int) {
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4, 64, 64]", newDimensions: "[1, 4, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 64, 64]", newDimensions: "[1, 512, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 64, 64]", newDimensions: "[1, 32, 16, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 4096]", newDimensions: "[1, 32, 16, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 4096]", newDimensions: "[1, 512, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4096, 512]", newDimensions: "[1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4096, 1, 512]", newDimensions: "[1, \(height / 8 * width / 8), 1, 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 4096, 512]", newDimensions: "[1, 1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 4096, 4096]", newDimensions: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 128, 128]", newDimensions: "[1, 512, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 128, 128]", newDimensions: "[1, 32, 16, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 256, 256]", newDimensions: "[1, 512, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 256, 256]", newDimensions: "[1, 32, 16, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 256, 256]", newDimensions: "[1, 256, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 256, 256]", newDimensions: "[1, 32, 8, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 512, 512]", newDimensions: "[1, 256, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 512, 512]", newDimensions: "[1, 32, 8, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 512, 512]", newDimensions: "[1, 128, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 512, 512]", newDimensions: "[1, 32, 4, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 3, 512, 512]", newDimensions: "[1, 3, \(height), \(width)]")
}

private func vaeEnSD(vaeMIL: String, height: Int, width: Int) {
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 8, 64, 64]", newDimensions: "[1, 8, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 4096, 512]", newDimensions: "[1, 1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 1, 4096, 4096]", newDimensions: "[1, 1, \(height / 8 * width / 8), \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4096, 1, 512]", newDimensions: "[1, \(height / 8 * width / 8), 1, 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 4096, 512]", newDimensions: "[1, \(height / 8 * width / 8), 512]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 4096]", newDimensions: "[1, 512, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 4096]", newDimensions: "[1, 32, 16, \(height / 8 * width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 64, 64]", newDimensions: "[1, 32, 16, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 64, 64]", newDimensions: "[1, 512, \(height / 8), \(width / 8)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 129, 129]", newDimensions: "[1, 512, \(height / 4 + 1), \(width / 4 + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 16, 128, 128]", newDimensions: "[1, 32, 16, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 512, 128, 128]", newDimensions: "[1, 512, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 128, 128]", newDimensions: "[1, 32, 8, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 128, 128]", newDimensions: "[1, 256, \(height / 4), \(width / 4)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 257, 257]", newDimensions: "[1, 256, \(height / 2 + 1), \(width / 2 + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 8, 256, 256]", newDimensions: "[1, 32, 8, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 256, 256, 256]", newDimensions: "[1, 256, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 256, 256]", newDimensions: "[1, 32, 4, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 256, 256]", newDimensions: "[1, 128, \(height / 2), \(width / 2)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 513, 513]", newDimensions: "[1, 128, \(height + 1), \(width + 1)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 128, 512, 512]", newDimensions: "[1, 128, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 32, 4, 512, 512]", newDimensions: "[1, 32, 4, \(height), \(width)]")
        modifyMILFile(path: vaeMIL, oldDimensions: "[1, 3, 512, 512]", newDimensions: "[1, 3, \(height), \(width)]")
}
