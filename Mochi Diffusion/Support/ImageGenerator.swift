//
//  ImageGenerator.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Combine
import CoreML
import OSLog
@preconcurrency import GuernikaKit
import UniformTypeIdentifiers

struct GenerationConfig: Sendable, Identifiable {
    let id = UUID()
    var pipelineConfig: SampleInput
    var isXL: Bool
    var autosaveImages: Bool
    var imageDir: String
    var imageType: String
    var numberOfImages: Int
    let model: SDModel
    var mlComputeUnit: MLComputeUnits
    var scheduler: Scheduler
    var upscaleGeneratedImages: Bool
    var controlNets: [String]
}

@Observable public final class ImageGenerator {

    static let shared = ImageGenerator()

    enum GeneratorError: Error {
        case imageDirectoryNoAccess
        case modelDirectoryNoAccess
        case modelSubDirectoriesNoAccess
        case noModelsFound
        case pipelineNotAvailable
        case requestedModelNotFound
    }

    enum State: Sendable {
        case ready(String?)
        case error(String)
        case loading
        case running(StableDiffusionProgress?)
    }

    private(set) var state = State.ready(nil)

    struct QueueProgress: Sendable {
        var index = 0
        var total = 0
    }

    private(set) var queueProgress = QueueProgress(index: 0, total: 0)

    public var pipeline: (any StableDiffusionPipeline)?

    private(set) var tokenizer: Tokenizer?

    private var generationStopped = false

    private(set) var lastStepGenerationElapsedTime: Double?

    private var generationStartTime: DispatchTime?

    private var currentPipelineHash: Int?
    
    private var lastSize: CGSize?

    func loadImages(imageDir: String) async throws -> ([SDImage], URL) {
        var finalImageDirURL: URL
        let fm = FileManager.default
        /// check if image autosave directory exists
        if imageDir.isEmpty {
            /// use default autosave directory
            finalImageDirURL = fm.homeDirectoryForCurrentUser
            finalImageDirURL.append(path: "MochiDiffusion/images", directoryHint: .isDirectory)
        } else {
            /// generate url from autosave directory
            finalImageDirURL = URL(fileURLWithPath: imageDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalImageDirURL.path(percentEncoded: false)) {
            print("Creating image autosave directory at: \"\(finalImageDirURL.path(percentEncoded: false))\"")
            try? fm.createDirectory(at: finalImageDirURL, withIntermediateDirectories: true)
        }
        let items = try fm.contentsOfDirectory(
            at: finalImageDirURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        let imageURLs = items
            .filter { $0.isFileURL }
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension) }
        var sdis: [SDImage] = []
        for url in imageURLs {
            guard let sdi = createSDImageFromURL(url) else { continue }
            sdis.append(sdi)
        }
        sdis.sort { $0.generatedDate < $1.generatedDate }
        return (sdis, finalImageDirURL)
    }

    private func controlNets(in controlNetDirectoryURL: URL) -> [SDControlNet] {
        let controlNetDirectoryPath = controlNetDirectoryURL.path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: controlNetDirectoryPath),
            let contentsOfControlNet = try? FileManager.default.contentsOfDirectory(atPath: controlNetDirectoryPath) else {
            return []
        }

        return contentsOfControlNet.compactMap { SDControlNet(url: controlNetDirectoryURL.appending(path: $0)) }
    }

    func getModels(modelDirectoryURL: URL, controlNetDirectoryURL: URL) async throws -> [SDModel] {
        var models: [SDModel] = []
        let fm = FileManager.default

        do {
            let controlNet = controlNets(in: controlNetDirectoryURL)
            let subDirs = try modelDirectoryURL.subDirectories()

            models = subDirs
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }
                .compactMap { url in
                    let controlledUnetMetadataPath = url.appending(components: "Unet.mlmodelc", "metadata.json").path(percentEncoded: false)
                    let hasControlNet = fm.fileExists(atPath: controlledUnetMetadataPath)
                    if hasControlNet {
                        let controlNetSymLinkPath = url.appending(component: "controlnet").path(percentEncoded: false)

                        if !fm.fileExists(atPath: controlNetSymLinkPath) {
                            try? fm.createSymbolicLink(atPath: controlNetSymLinkPath, withDestinationPath: controlNetDirectoryURL.path(percentEncoded: false))
                        }
                    }

                    return SDModel(url: url, name: url.lastPathComponent, controlNet: hasControlNet ? controlNet : [])
                }
        } catch {
            await updateState(.error("Could not get model subdirectories."))
            throw GeneratorError.modelSubDirectoriesNoAccess
        }
        if models.isEmpty {
            await updateState(.error("No models found under: \(modelDirectoryURL.path(percentEncoded: false))"))
            throw GeneratorError.noModelsFound
        }
        return models
    }

    func loadPipeline(model: SDModel, controlNet: [String] = [], computeUnit: MLComputeUnits, reduceMemory: Bool) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            await updateState(.error("Couldn't load \(model.name) because it doesn't exist."))
            throw GeneratorError.requestedModelNotFound
        }
        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(controlNet)
        hasher.combine(computeUnit)
        hasher.combine(reduceMemory)
        let hash = hasher.finalize()
        let cSize = await CGSize(width: ImageController.shared.width, height: ImageController.shared.height)
        
        if hash == self.currentPipelineHash {
            if await ImageController.shared.startingImage != nil && lastSize == cSize {
                return
            } else if await ImageController.shared.startingImage == nil{
                return
            }
        }
        
        lastSize = await CGSize(width: ImageController.shared.width, height: ImageController.shared.height)
        await updateState(.loading)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnit
        await modifyInputSize(model.url, height: ImageController.shared.height, width: ImageController.shared.width)
        let modelresource = try GuernikaKit.load(at: model.url)
        
        if FileManager.default.fileExists(atPath: model.url.path() + "WuerstchenPrior.mlmodelc"){
            //pipeline = modelresource as? WuerstchenPipeline
        }else if model.isXL {
            self.pipeline = modelresource as! StableDiffusionXLPipeline
        } else if modelresource.sampleSize.width <= CGFloat(768) {
            self.pipeline = modelresource as! StableDiffusionMainPipeline
        }

        self.pipeline?.reduceMemory = reduceMemory
        self.currentPipelineHash = hash
        self.tokenizer = Tokenizer(modelDir: model.url)
        await updateState(.ready(nil))
    }

    func generate(_ inputConfig: GenerationConfig) async throws {
        guard let pipeline = pipeline else {
            await updateState(.error("Pipeline is not loaded."))
            throw GeneratorError.pipelineNotAvailable
        }
        await updateState(.loading)
        generationStopped = false
       
        var config = inputConfig
        config.pipelineConfig.seed = config.pipelineConfig.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : config.pipelineConfig.seed
        
        var sdi = SDImage()
        sdi.prompt = config.pipelineConfig.prompt
        sdi.negativePrompt = config.pipelineConfig.negativePrompt
        sdi.model = config.model.name
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = config.pipelineConfig.stepCount
        sdi.guidanceScale = Double(config.pipelineConfig.guidanceScale)
        
        try await hackVAE(model: config.model)
        
        for index in 0 ..< config.numberOfImages {
            await updateQueueProgress(QueueProgress(index: index, total: inputConfig.numberOfImages))
            generationStartTime = DispatchTime.now()
            
            let image = try pipeline.generateImages(input: config.pipelineConfig) { progress in

                Task { @MainActor in
                    state = .running(progress)
                    let endTime = DispatchTime.now()
                    lastStepGenerationElapsedTime = Double(endTime.uptimeNanoseconds - (generationStartTime?.uptimeNanoseconds ?? 0))
                    generationStartTime = endTime
                }

                Task {
                    let currentImage = progress.currentLatentSample
                    if await ImageController.shared.showHighqualityPreview{
                        ImageStore.shared.setCurrentGenerating(image: try pipeline.decodeToImage(currentImage))
                    }else{
                        ImageStore.shared.setCurrentGenerating(image: pipeline.latentToImage(currentImage))
                    }
                }

                return !generationStopped
            }
            if generationStopped {
                break
            }
            
            guard let image = image else { continue }
            if config.upscaleGeneratedImages {
                guard let upscaledImg = await Upscaler.shared.upscale(cgImage: image) else { continue }
                sdi.image = upscaledImg
                sdi.aspectRatio = CGFloat(Double(upscaledImg.width) / Double(upscaledImg.height))
                sdi.upscaler = "RealESRGAN"
            } else {
                sdi.image = image
                sdi.aspectRatio = CGFloat(Double(image.width) / Double(image.height))
            }
            sdi.id = UUID()
            sdi.seed = config.pipelineConfig.seed
            sdi.generatedDate = Date.now
            sdi.path = ""

            if config.autosaveImages && !config.imageDir.isEmpty {
                var pathURL = URL(fileURLWithPath: config.imageDir, isDirectory: true)
                let count = ImageStore.shared.images.endIndex + 1
                pathURL.append(path: sdi.filenameWithoutExtension(count: count))

                let type = UTType.fromString(config.imageType)
                guard let path = await sdi.save(pathURL, type: type) else { continue }
                sdi.path = path.path(percentEncoded: false)
            }
            ImageStore.shared.add(sdi)
            config.pipelineConfig.seed += 1
        }
        await updateState(.ready(nil))
    }
    
    func hackVAE(model: SDModel) async throws {
        let resourcePath = model.url.path()
        if model.isXL{
            if FileManager.default.fileExists(atPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak"){
                let vaedecoderMIL = resourcePath + "VAEDecoder.mlmodelc/model.mil"
                try FileManager.default.removeItem(atPath: vaedecoderMIL)
                try FileManager.default.copyItem(atPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak", toPath: vaedecoderMIL)
                await vaeDeSDXL(vaeMIL: vaedecoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }else{
                let vaedecoderMIL = resourcePath + "VAEDecoder.mlmodelc/model.mil"
                try FileManager.default.copyItem(atPath: vaedecoderMIL, toPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak")
                try FileManager.default.removeItem(atPath: resourcePath + "VAEDecoder.mlmodelc/coremldata.bin")
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "de-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: resourcePath + "VAEDecoder.mlmodelc/coremldata.bin"))
                await vaeDeSDXL(vaeMIL: vaedecoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }
            
            if FileManager.default.fileExists(atPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak"){
                let vaeencoderMIL = resourcePath + "VAEEncoder.mlmodelc/model.mil"
                try FileManager.default.removeItem(atPath: vaeencoderMIL)
                try FileManager.default.copyItem(atPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak", toPath: vaeencoderMIL)
                await vaeEnSDXL(vaeMIL: vaeencoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }else{
                let vaeencoderMIL = resourcePath + "VAEEncoder.mlmodelc/model.mil"
                try FileManager.default.copyItem(atPath: vaeencoderMIL, toPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak")
                try FileManager.default.removeItem(atPath: resourcePath + "VAEEncoder.mlmodelc/coremldata.bin")
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "en-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: resourcePath + "VAEEncoder.mlmodelc/coremldata.bin"))
                await vaeEnSDXL(vaeMIL: vaeencoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }
        }else{
            if FileManager.default.fileExists(atPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak"){
                let vaedecoderMIL = resourcePath + "VAEDecoder.mlmodelc/model.mil"
                try FileManager.default.removeItem(atPath: vaedecoderMIL)
                try FileManager.default.copyItem(atPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak", toPath: vaedecoderMIL)
                await vaeDeSD(vaeMIL: vaedecoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }else{
                let vaedecoderMIL = resourcePath + "VAEDecoder.mlmodelc/model.mil"
                try FileManager.default.copyItem(atPath: vaedecoderMIL, toPath: resourcePath + "VAEDecoder.mlmodelc/model.mil.bak")
                try FileManager.default.removeItem(atPath: resourcePath + "VAEDecoder.mlmodelc/coremldata.bin")
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "de-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: resourcePath + "VAEDecoder.mlmodelc/coremldata.bin"))
                await vaeDeSD(vaeMIL: vaedecoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }
            
            if FileManager.default.fileExists(atPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak"){
                let vaeencoderMIL = resourcePath + "VAEEncoder.mlmodelc/model.mil"
                try FileManager.default.removeItem(atPath: vaeencoderMIL)
                try FileManager.default.copyItem(atPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak", toPath: vaeencoderMIL)
                await vaeEnSD(vaeMIL: vaeencoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }else{
                let vaeencoderMIL = resourcePath + "VAEEncoder.mlmodelc/model.mil"
                try FileManager.default.copyItem(atPath: vaeencoderMIL, toPath: resourcePath + "VAEEncoder.mlmodelc/model.mil.bak")
                try FileManager.default.removeItem(atPath: resourcePath + "VAEEncoder.mlmodelc/coremldata.bin")
                try FileManager.default.copyItem(at: Bundle.main.url(forResource: "en-coremldata", withExtension: "bin")!, to: URL(fileURLWithPath: resourcePath + "VAEEncoder.mlmodelc/coremldata.bin"))
                await vaeEnSD(vaeMIL: vaeencoderMIL, height: ImageController.shared.height, width: ImageController.shared.width)
            }
        }
    }

    func modifyMILFile(path: String, oldDimensions: String, newDimensions: String) {
        do {
            let fileContent = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            let modifiedContent = fileContent.replacingOccurrences(of: oldDimensions, with: newDimensions)
            try modifiedContent.write(to: URL(fileURLWithPath: path),atomically: false, encoding: .utf8)
        } catch {
            print("Error modifying MIL file: \(error)")
        }
    }
    
    func modifyInputSize(_ url: URL, height: Int, width: Int) {
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
    
    func vaeDeSDXL(vaeMIL: String, height: Int, width: Int) {
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
    
    func vaeEnSDXL(vaeMIL: String, height: Int, width: Int) {
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
    
    func vaeDeSD(vaeMIL: String, height: Int, width: Int) {
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
    
    func vaeEnSD(vaeMIL: String, height: Int, width: Int) {
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
    
    func stopGenerate() async {
        generationStopped = true
    }

    func updateState(_ state: State) async {
        Task { @MainActor in
            self.state = state
        }
    }

    private func updateQueueProgress(_ queueProgress: QueueProgress) async {
        Task { @MainActor in
            self.queueProgress = queueProgress
        }
    }
}

extension URL {
    func subDirectories() throws -> [URL] {
        guard hasDirectoryPath else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
    }
}
