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

    func load(model: SDModel, controlNet: [String] = [], computeUnit: MLComputeUnits, reduceMemory: Bool) async throws {
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
            controlNet: controlNet,
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

            let images = try pipeline.generateImages(configuration: config.pipelineConfig) { [config] progress in
                Task { @MainActor in
                    state = .running(progress)
                }

                Task {
                    if config.pipelineConfig.useDenoisedIntermediates, let currentImage = progress.currentImages.last {
                        await ImageStore.shared.setCurrentGenerating(image: currentImage)
                    } else {
                        await ImageStore.shared.setCurrentGenerating(image: nil)
                    }
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
