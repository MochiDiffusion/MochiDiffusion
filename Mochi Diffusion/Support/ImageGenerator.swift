//
//  ImageGenerator.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Combine
import CoreML
import OSLog
@preconcurrency import StableDiffusion

struct GenerationConfig: Sendable {
    var pipelineConfig: StableDiffusionPipeline.Configuration
    var autosaveImages: Bool
    var imageDir: String
    var numberOfImages: Int
    var model: String
    var mlComputeUnit: MLComputeUnits
    var scheduler: Scheduler
    var upscaleGeneratedImages: Bool
}

class ImageGenerator: ObservableObject {

    static let shared = ImageGenerator()

    private lazy var logger = Logger()

    enum GeneratorError: Error {
        case imageDirectoryNoAccess
        case modelDirectoryNoAccess
        case modelSubDirectoriesNoAccess
        case noModelsFound
        case pipelineNotAvailable
        case requestedModelNotFound
    }

    private var pipeline: StableDiffusionPipeline?

    private(set) var tokenizer: Tokenizer?

    private var generationStopped = false

    func loadImages(imageDir: String) async throws -> ([SDImage], URL) {
        logger.info("Started loading image autosave directory at: \"\(imageDir)\"")
        var finalImageDirURL: URL
        let fm = FileManager.default
        /// check if image autosave directory exists
        if imageDir.isEmpty {
            /// use default autosave directory
            guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw GeneratorError.imageDirectoryNoAccess
            }
            finalImageDirURL = documentsDir
            finalImageDirURL.append(path: "MochiDiffusion/images", directoryHint: .isDirectory)
        } else {
            /// generate url from autosave directory
            finalImageDirURL = URL(fileURLWithPath: imageDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalImageDirURL.path(percentEncoded: false)) {
            logger.notice("Creating image autosave directory at: \"\(finalImageDirURL.path(percentEncoded: false))\"")
            try? fm.createDirectory(at: finalImageDirURL, withIntermediateDirectories: true)
        }
        let items = try fm.contentsOfDirectory(
            at: finalImageDirURL,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        )
        let imageURLs = items.filter { $0.isFileURL && ($0.pathExtension == "png" || $0.pathExtension == "jpg") }
        var sdis: [SDImage] = []
        for url in imageURLs {
            guard let sdi = createSDImageFromURL(url) else { continue }
            sdis.append(sdi)
        }
        sdis.sort { $0.generatedDate < $1.generatedDate }
        return (sdis, finalImageDirURL)
    }

    func getModels(modelDir: String) async throws -> ([SDModel], URL) {
        logger.info("Started loading model directory at: \"\(modelDir)\"")
        var models: [SDModel] = []
        var finalModelDirURL: URL
        let fm = FileManager.default
        /// check if saved model directory exists
        if modelDir.isEmpty {
            /// use default model directory
            guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                throw GeneratorError.modelDirectoryNoAccess
            }
            finalModelDirURL = documentsDir
            finalModelDirURL.append(path: "MochiDiffusion/models/", directoryHint: .isDirectory)
        } else {
            /// generate url from saved model directory
            finalModelDirURL = URL(fileURLWithPath: modelDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalModelDirURL.path(percentEncoded: false)) {
            logger.notice("Creating models directory at: \"\(finalModelDirURL.path(percentEncoded: false))\"")
            try? fm.createDirectory(at: finalModelDirURL, withIntermediateDirectories: true)
        }
        do {
            let subDirs = try finalModelDirURL.subDirectories()
            subDirs
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }
                .forEach {
                    let model = SDModel(url: $0, name: $0.lastPathComponent)
                    models.append(model)
                }
        } catch {
            logger.notice("Could not get model subdirectories under: \"\(finalModelDirURL.path(percentEncoded: false))\"")
            throw GeneratorError.modelSubDirectoriesNoAccess
        }
        if models.isEmpty {
            logger.notice("No models found under: \(finalModelDirURL.path(percentEncoded: false))")
            throw GeneratorError.noModelsFound
        }
        return (models, finalModelDirURL)
    }

    func load(model: SDModel, computeUnit: MLComputeUnits, reduceMemory: Bool) async throws {
        logger.info("Started loading model: \"\(model.name)\"")
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            logger.info("Couldn't find model \"\(model.name)\" at: \"\(model.url.path(percentEncoded: false))\"")
            throw GeneratorError.requestedModelNotFound
        }
        logger.info("Found model: \"\(model.name)\"")
        let config = MLModelConfiguration()
        config.computeUnits = computeUnit
        self.pipeline = try StableDiffusionPipeline(
            resourcesAt: model.url,
            configuration: config,
            disableSafety: true,
            reduceMemory: reduceMemory
        )
        self.tokenizer = Tokenizer(modelDir: model.url)
        logger.info("Stable Diffusion pipeline successfully loaded")
    }

    func generate(_ inputConfig: GenerationConfig) async throws {
        guard let pipeline = pipeline else {
            throw GeneratorError.pipelineNotAvailable
        }
        generationStopped = false
        var config = inputConfig
        config.pipelineConfig.seed = config.pipelineConfig.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : config.pipelineConfig.seed

        var sdi = SDImage()
        sdi.prompt = config.pipelineConfig.prompt
        sdi.negativePrompt = config.pipelineConfig.negativePrompt
        sdi.model = config.model
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = config.pipelineConfig.stepCount
        sdi.guidanceScale = Double(config.pipelineConfig.guidanceScale)

        for index in 0 ..< config.numberOfImages {
            await ImageController.shared.updateQueueProgress(ImageController.QueueProgress(index: index, total: inputConfig.numberOfImages))

            let images = try pipeline.generateImages(configuration: config.pipelineConfig) { progress in
                Task { @MainActor in
                    await ImageController.shared.updateState(.running(progress))
                }
                return !generationStopped
            }
            if generationStopped {
                break
            }
            for image in images {
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
                    let count = await ImageStore.shared.images.endIndex + 1
                    let filename = "\(String(config.pipelineConfig.prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(config.pipelineConfig.seed).png"
                    pathURL.append(path: filename)
                    await sdi.save(pathURL)
                    sdi.path = pathURL.path(percentEncoded: false)
                }
                await ImageStore.shared.add(sdi)
            }
            config.pipelineConfig.seed += 1
        }
        await ImageController.shared.updateState(.ready(nil))
    }

    func stopGenerate() async {
        generationStopped = true
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
        .filter(\.hasDirectoryPath)
    }
}
