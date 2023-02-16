//
//  ImageGenerator.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import Combine
import CoreML
import OSLog
import StableDiffusion

struct GenerationConfig {
    var pipelineConfig: StableDiffusionPipeline.Configuration
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
        case modelDirectoryNoAccess
        case modelSubDirectoriesNoAccess
        case noModelsFound
        case pipelineNotAvailable
        case requestedModelNotFound
    }

    enum State {
        case idle
        case ready
        case error(String)
        case loading
        case running(StableDiffusionProgress?)
    }

    @MainActor
    @Published
    private(set) var state = State.idle

    struct QueueProgress {
        var index = 0
        var total = 0
    }

    @MainActor
    @Published
    private(set) var queueProgress = QueueProgress(index: 0, total: 0)

    private var pipeline: StableDiffusionPipeline?

    private(set) var tokenizer: Tokenizer?

    private var generationStopped = false

    func getModels(modelDir: String) async throws -> ([SDModel], URL) {
        logger.info("Started loading model directory at: \"\(modelDir)\"")
        var models: [SDModel] = []
        var finalModelDirURL: URL
        let fm = FileManager.default
        // check if saved model directory exists
        if modelDir.isEmpty {
            // use default model directory
            guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                await updateState(.error("Couldn't access model directory."))
                throw GeneratorError.modelDirectoryNoAccess
            }
            finalModelDirURL = documentsDir
            finalModelDirURL.append(path: "MochiDiffusion/models/", directoryHint: .isDirectory)
        } else {
            // generate url from saved model directory
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
        logger.info("Started loading model: \"\(model.name)\"")
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            logger.info("Couldn't find model \"\(model.name)\" at: \"\(model.url.path(percentEncoded: false))\"")
            await updateState(.error("Couldn't load \(model.name) because it doesn't exist."))
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
        await updateState(.ready)
    }

    func generate(_ inputConfig: GenerationConfig) async throws {
        guard let pipeline = pipeline else {
            await updateState(.error("Pipeline is not loaded."))
            throw GeneratorError.pipelineNotAvailable
        }
        await updateState(.loading)
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
                    guard let upscaledImg = Upscaler.shared.upscale(cgImage: image) else { continue }
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
                await ImageStore.shared.add(sdi)
            }
            config.pipelineConfig.seed += 1
        }
        await updateState(.ready)
    }

    func stopGenerate() async {
        generationStopped = true
    }

    private func updateState(_ state: State) async {
        Task { @MainActor in
            self.state = state
        }
    }

    private func updateQueueProgress(_ queueProgress: QueueProgress) async {
        Task { @MainActor in
            self.queueProgress = queueProgress
        }
    }

    private func upscale(_ image: CGImage) async -> CGImage? {
        fatalError()
    }
}
