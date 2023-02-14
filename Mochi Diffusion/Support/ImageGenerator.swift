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

@MainActor
final class ImageGenerator: ObservableObject {

    static let shared = ImageGenerator()

    private lazy var logger = Logger()

    enum GeneratorError: Error {
        case pipelineNotAvailable
        case modelNotFound
    }

    enum State {
        case idle
        case running(StableDiffusionProgress?)
    }

    @Published
    private(set) var state = State.idle

    struct QueueProgress {
        var index = 0
        var total = 0
    }

    @Published
    private(set) var queueProgress = QueueProgress(index: 0, total: 0)

    private var pipeline: StableDiffusionPipeline?

    private(set) var tokenizer: Tokenizer?

    private var generationStopped = false

    func load(
        model: SDModel,
        computeUnit: MLComputeUnits,
        reduceMemory: Bool
    ) async throws {
        logger.info("Started loading model: \"\(model.name)\"")
        let fm = FileManager.default
        if !fm.fileExists(atPath: model.url.path) {
            logger.info("Couldn't find model \"\(model.name)\" at: \"\(model.url.path(percentEncoded: false))\"")
            throw GeneratorError.modelNotFound
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

    func generate(_ inputConfig: GenerationConfig) async throws -> [SDImage] {
        guard let pipeline = pipeline else {
            throw GeneratorError.pipelineNotAvailable
        }
        var config = inputConfig
        config.pipelineConfig.seed = config.pipelineConfig.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : config.pipelineConfig.seed

        var sdImages = [SDImage]()
        var sdi = SDImage()
        sdi.prompt = config.pipelineConfig.prompt
        sdi.negativePrompt = config.pipelineConfig.negativePrompt
        sdi.model = config.model
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = config.pipelineConfig.stepCount
        sdi.guidanceScale = Double(config.pipelineConfig.guidanceScale)

        for index in 0 ..< config.numberOfImages {
            queueProgress = QueueProgress(index: index, total: config.numberOfImages)
            let images = try pipeline.generateImages(configuration: config.pipelineConfig) { progress in
                state = .running(progress)
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
                } else {
                    sdi.image = image
                    sdi.aspectRatio = CGFloat(Double(image.width) / Double(image.height))
                }
                sdi.id = UUID()
                sdi.seed = config.pipelineConfig.seed
                sdi.generatedDate = Date.now
                sdImages.append(sdi)
            }
            config.pipelineConfig.seed += 1
        }
        state = .idle
        return sdImages
    }

    func stopGenerate() async {
        generationStopped = true
    }

    private func upscale(_ image: CGImage) async -> CGImage? {
        fatalError()
    }

    private var isRunning: Bool {
        guard case .running = state else { return false }
        return true
    }
}
