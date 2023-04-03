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
import UniformTypeIdentifiers

struct GenerationConfig: Sendable {
    var pipelineConfig: StableDiffusionPipeline.Configuration
    var autosaveImages: Bool
    var imageDir: String
    var imageType: String
    var numberOfImages: Int
    var model: String
    var mlComputeUnit: MLComputeUnits
    var scheduler: Scheduler
    var upscaleGeneratedImages: Bool
}

class ImageGenerator: ObservableObject {

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
        case idle
        case ready(String?)
        case error(String)
        case loading
        case running(StableDiffusionProgress?)
    }

    @MainActor
    @Published
    private(set) var state = State.idle

    struct QueueProgress: Sendable {
        var index = 0
        var total = 0
    }

    @MainActor
    @Published
    private(set) var queueProgress = QueueProgress(index: 0, total: 0)

    private var pipeline: StableDiffusionPipeline?

    private(set) var tokenizer: Tokenizer?

    private var generationStopped = false

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

    func getModels(modelDir: String) async throws -> ([SDModel], URL) {
        var models: [SDModel] = []
        var finalModelDirURL: URL
        let fm = FileManager.default
        /// check if saved model directory exists
        if modelDir.isEmpty {
            /// use default model directory
            finalModelDirURL = fm.homeDirectoryForCurrentUser
            finalModelDirURL.append(path: "MochiDiffusion/models/", directoryHint: .isDirectory)
        } else {
            /// generate url from saved model directory
            finalModelDirURL = URL(fileURLWithPath: modelDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalModelDirURL.path(percentEncoded: false)) {
            print("Creating models directory at: \"\(finalModelDirURL.path(percentEncoded: false))\"")
            try? fm.createDirectory(at: finalModelDirURL, withIntermediateDirectories: true)
        }
        do {
            let subDirs = try finalModelDirURL.subDirectories()
            models = subDirs
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }
                .compactMap { SDModel(url: $0, name: $0.lastPathComponent) }
        } catch {
            await updateState(.error("Could not get model subdirectories."))
            throw GeneratorError.modelSubDirectoriesNoAccess
        }
        if models.isEmpty {
            await updateState(.error("No models found under: \(finalModelDirURL.path(percentEncoded: false))"))
            throw GeneratorError.noModelsFound
        }
        return (models, finalModelDirURL)
    }

    func load(model: SDModel, computeUnit: MLComputeUnits, reduceMemory: Bool) async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            await updateState(.error("Couldn't load \(model.name) because it doesn't exist."))
            throw GeneratorError.requestedModelNotFound
        }
        await updateState(.loading)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnit
        self.pipeline = try StableDiffusionPipeline(
            resourcesAt: model.url,
            configuration: config,
            disableSafety: true,
            reduceMemory: reduceMemory
        )
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
        sdi.model = config.model
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = config.pipelineConfig.stepCount
        sdi.guidanceScale = Double(config.pipelineConfig.guidanceScale)

        for index in 0 ..< config.numberOfImages {
            await updateQueueProgress(QueueProgress(index: index, total: inputConfig.numberOfImages))

            let images = try pipeline.generateImages(configuration: config.pipelineConfig) { progress in
                Task { @MainActor in
                    state = .running(progress)
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
                    pathURL.append(path: sdi.filenameWithoutExtension(count: count))

                    let type = UTType.fromString(config.imageType)
                    guard let path = await sdi.save(pathURL, type: type) else { continue }
                    sdi.path = path.path(percentEncoded: false)
                }
                await ImageStore.shared.add(sdi)
            }
            config.pipelineConfig.seed += 1
        }
        await updateState(.ready(nil))
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
        .filter(\.hasDirectoryPath)
    }
}
