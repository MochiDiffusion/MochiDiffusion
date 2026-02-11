//
//  ImageGenerator.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import StableDiffusion
import UniformTypeIdentifiers

struct SDGenerationConfig: Identifiable {
    let id = UUID()

    let prompt: String
    let negativePrompt: String
    let startingImage: CGImage?
    let controlNetInputs: [CGImage]
    let model: SDModel
    var mlComputeUnit: MLComputeUnits
    var controlNets: [String]
    let strength: Float
    let stepCount: Int
    let guidanceScale: Float
    let disableSafety: Bool
    var scheduler: Scheduler
    let useDenoisedIntermediates: Bool
    let seed: UInt32
    var numberOfImages: Int
    var imageDir: String
    var imageType: String
}

public final class SDImageGenerator: ImageGenerator {

    enum GeneratorError: Error {
        case imageDirectoryNoAccess
        case modelDirectoryNoAccess
        case modelSubDirectoriesNoAccess
        case noModelsFound
        case pipelineNotAvailable
        case requestedModelNotFound
        case startingImageProvidedWithoutEncoder
    }

    private var pipeline: (any StableDiffusionPipelineProtocol)?

    private var generationStopped = false

    private var generationStartTime: DispatchTime?

    private var currentPipelineHash: Int?

    func loadPipeline(
        model: SDModel,
        controlNet: [String] = [],
        computeUnit: MLComputeUnits,
        reduceMemory: Bool,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void
    ) async throws {
        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(controlNet)
        hasher.combine(computeUnit)
        hasher.combine(reduceMemory)
        let hash = hasher.finalize()
        guard hash != self.currentPipelineHash else { return }

        await onState(.loading)
        let config = MLModelConfiguration()
        config.computeUnits = computeUnit

        if model.type == .sdxl {
            self.pipeline = try StableDiffusionXLPipeline(
                resourcesAt: model.url,
                configuration: config,
                reduceMemory: reduceMemory
            )
        } else if model.type == .sd3 {
            self.pipeline = try StableDiffusion3Pipeline(
                resourcesAt: model.url,
                configuration: config,
                reduceMemory: reduceMemory
            )
        } else {
            self.pipeline = try StableDiffusionPipeline(
                resourcesAt: model.url,
                controlNet: controlNet,
                configuration: config,
                disableSafety: true,
                reduceMemory: reduceMemory
            )
        }

        self.currentPipelineHash = hash
        await onState(.ready(nil))
    }

    func generate(
        request: GenerationRequest,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard
            case .sd(
                let model,
                let computeUnit,
                let controlNets,
                let reduceMemory
            ) = request.pipeline
        else {
            await onState(.error("Pipeline is not loaded."))
            throw GeneratorError.pipelineNotAvailable
        }

        let config = makeGenerationConfig(
            from: request,
            model: model,
            computeUnit: computeUnit,
            controlNets: controlNets
        )

        try await loadPipeline(
            model: model,
            controlNet: config.controlNets,
            computeUnit: computeUnit,
            reduceMemory: reduceMemory,
            onState: onState
        )

        try await generate(
            config,
            generationPipeline: request.pipeline,
            onState: onState,
            onProgress: onProgress,
            onPreview: onPreview,
            onResult: onResult
        )
    }

    func generate(
        _ config: SDGenerationConfig,
        generationPipeline: GenerationPipeline,
        onState: @escaping @Sendable (GenerationState.Status) async -> Void,
        onProgress: @escaping @Sendable (GenerationState.Progress, Double?) async -> Void,
        onPreview: @escaping @Sendable (CGImage?) async -> Void,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard let pipeline = pipeline else {
            await onState(.error("Pipeline is not loaded."))
            throw GeneratorError.pipelineNotAvailable
        }
        await onState(.loading)
        generationStopped = false
        defer {
            Task {
                await onPreview(nil)
            }
        }

        var pipelineConfig = StableDiffusionPipeline.Configuration(prompt: config.prompt)
        pipelineConfig.negativePrompt = config.negativePrompt
        pipelineConfig.seed = config.seed
        pipelineConfig.startingImage = config.startingImage
        pipelineConfig.strength = config.strength
        pipelineConfig.stepCount = config.stepCount
        pipelineConfig.seed = config.seed
        pipelineConfig.guidanceScale = config.guidanceScale
        pipelineConfig.disableSafety = config.disableSafety
        pipelineConfig.schedulerType = convertScheduler(config.scheduler)
        pipelineConfig.controlNetInputs = config.controlNetInputs
        pipelineConfig.useDenoisedIntermediates = config.useDenoisedIntermediates

        if config.model.type == .sdxl {
            pipelineConfig.encoderScaleFactor = 0.13025
            pipelineConfig.decoderScaleFactor = 0.13025
            pipelineConfig.schedulerTimestepSpacing = .karras
        }

        if config.model.type == .sd3 {
            pipelineConfig.schedulerTimestepShift = 3.0
        }

        var sdi = SDImage()
        sdi.prompt = pipelineConfig.prompt
        sdi.negativePrompt = pipelineConfig.negativePrompt
        sdi.model = config.model.name
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = pipelineConfig.stepCount
        sdi.guidanceScale = Double(pipelineConfig.guidanceScale)

        for _ in 0..<config.numberOfImages {
            generationStartTime = DispatchTime.now()
            let images = try pipeline.generateImages(configuration: pipelineConfig) {
                progress in

                Task {
                    let endTime = DispatchTime.now()
                    let elapsed = Double(
                        endTime.uptimeNanoseconds - (generationStartTime?.uptimeNanoseconds ?? 0))
                    await onProgress(
                        GenerationState.Progress(
                            step: progress.step,
                            stepCount: progress.stepCount
                        ),
                        elapsed
                    )
                    generationStartTime = endTime
                }

                Task {
                    if pipelineConfig.useDenoisedIntermediates,
                        let currentImage = progress.currentImages.last
                    {
                        await onPreview(currentImage)
                    } else {
                        await onPreview(nil)
                    }
                }

                return !generationStopped
            }
            if generationStopped {
                break
            }
            for image in images {
                guard let image = image else { continue }
                sdi.image = image
                sdi.aspectRatio = CGFloat(Double(image.width) / Double(image.height))
                sdi.id = UUID()
                sdi.seed = pipelineConfig.seed
                sdi.generatedDate = Date.now
                sdi.path = ""

                let type = UTType.fromString(config.imageType)
                guard
                    let data = await sdi.imageData(
                        type,
                        metadataFields: generationPipeline.metadataFields
                    )
                else { continue }
                let metadata = GenerationMetadata(
                    prompt: sdi.prompt,
                    negativePrompt: sdi.negativePrompt,
                    width: image.width,
                    height: image.height,
                    pipeline: generationPipeline,
                    model: sdi.model,
                    scheduler: sdi.scheduler,
                    seed: sdi.seed,
                    steps: sdi.steps,
                    guidanceScale: sdi.guidanceScale,
                    generatedDate: sdi.generatedDate,
                    metadataFields: generationPipeline.metadataFields
                )
                let result = GenerationResult(metadata: metadata, imageData: data)
                try await onResult(result)
            }
            pipelineConfig.seed += 1
        }
        await onState(.ready(nil))
    }

    func stopGenerate() async {
        generationStopped = true
    }
}

extension SDImageGenerator {
    fileprivate func makeGenerationConfig(
        from request: GenerationRequest,
        model: SDModel,
        computeUnit: MLComputeUnits,
        controlNets: [String]
    ) -> SDGenerationConfig {
        var startingImage: CGImage?
        var controlNetInputs: [CGImage] = []
        var resolvedControlNets: [String] = []

        if let size = model.inputSize {
            if let data = request.startingImageData {
                startingImage = CGImage.fromData(data)?.scaledAndCroppedTo(size: size)
            }

            for (name, data) in zip(controlNets, request.controlNetInputs) {
                guard let image = CGImage.fromData(data)?.scaledAndCroppedTo(size: size) else {
                    continue
                }
                controlNetInputs.append(image)
                resolvedControlNets.append(name)
            }
        }

        return SDGenerationConfig(
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            startingImage: startingImage,
            controlNetInputs: controlNetInputs,
            model: model,
            mlComputeUnit: computeUnit,
            controlNets: resolvedControlNets,
            strength: request.strength,
            stepCount: request.stepCount,
            guidanceScale: request.guidanceScale,
            disableSafety: request.disableSafety,
            scheduler: request.scheduler,
            useDenoisedIntermediates: request.useDenoisedIntermediates,
            seed: request.seed,
            numberOfImages: request.numberOfImages,
            imageDir: request.imageDir,
            imageType: request.imageType
        )
    }
}
