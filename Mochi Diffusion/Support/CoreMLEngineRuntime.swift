//
//  CoreMLEngineRuntime.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import StableDiffusion
import UniformTypeIdentifiers

/// Resolved values for one Core ML generation, in the shape the Apple pipeline
/// wants them.
nonisolated struct CoreMLGenerationConfig {
    let prompt: String
    let negativePrompt: String
    let startingImage: CGImage?
    let startingImageName: String
    let controlNetImageName: String
    let inputImageNames: [String]
    let controlNetInputs: [CGImage]
    let model: SDModel
    let mlComputeUnit: MLComputeUnits
    let controlNets: [String]
    let strength: Float
    let stepCount: Int
    let guidanceScale: Float
    let disableSafety: Bool
    let scheduler: Scheduler
    let useDenoisedIntermediates: Bool
    let seed: UInt32
    let numberOfImages: Int
    let imageType: String
}

/// Runs Core ML Stable Diffusion requests and owns the loaded pipeline between
/// them.
///
/// An `actor`, which is what let the previous `@unchecked Sendable` conformance go
/// away. That conformance was justified by a comment asserting `GenerationService`
/// serialized generation — an invariant the compiler could not see and the
/// per-engine-lane work in §11.7 would have silently broken. The pipeline and its
/// cache key are now ordinary isolated state.
///
/// The blocking `generateImages` call runs *inside* the actor, so it occupies the
/// actor's executor for the length of a generation. That is deliberate and it is a
/// trade: moving it out would mean sending the non-`Sendable` pipeline across an
/// isolation boundary and back, which Swift's region analysis cannot prove safe
/// for a value read out of actor storage. Nothing deadlocks on it, because the
/// only two things that would want in during a generation do not come here —
/// cancellation goes to the ``GenerationSession``, and the queue admits one
/// request at a time.
actor CoreMLEngineRuntime: GenerationEngineRuntime {
    private var pipeline: (any StableDiffusionPipelineProtocol)?
    private var currentPipelineHash: Int?
    private let modelRepository: ModelRepository

    init(modelRepository: ModelRepository = ModelRepository()) {
        self.modelRepository = modelRepository
    }

    func run(
        request: GenerationRequest,
        session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        // The single downcast of this engine's payload. A mismatch means a
        // request reached the wrong runtime, which is a wiring bug, so it is
        // reported as an invariant failure rather than as a pipeline the user
        // could fix. `AnyGenerationEngine.accepts(payload:)` rejects it at
        // enqueue, so reaching here means that check was bypassed.
        guard let payload = request.payload as? CoreMLGenerationPayload else {
            throw EngineError.payloadDoesNotBelongToEngine(engine: .coreMLStableDiffusion)
        }

        // Moved out of the queue, which used to downcast this payload itself to
        // ask the question. Whether a model is still on disk is knowledge about
        // this engine's models, so it belongs to this engine.
        guard await modelRepository.modelExists(payload.model) else {
            throw GenerationError.requestedModelNotFound
        }

        let config = makeConfig(from: request, payload: payload)

        try loadPipelineIfNeeded(
            model: payload.model,
            controlNet: config.controlNets,
            controlNetDirectory: payload.controlNetDirectory,
            computeUnit: payload.computeUnit,
            reduceMemory: payload.reduceMemory,
            session: session
        )

        try await generate(config, request: request, session: session, onResult: onResult)
    }

    /// Loads the pipeline unless the one already loaded was built from the same
    /// inputs. Synchronous: it is called from inside the actor and the work is
    /// the load itself, not something to await.
    private func loadPipelineIfNeeded(
        model: SDModel,
        controlNet: [String],
        controlNetDirectory: URL,
        computeUnit: MLComputeUnits,
        reduceMemory: Bool,
        session: GenerationSession
    ) throws {
        // Relinking happens *before* the cache check, and its result is part of
        // the key. Both matter: changing the configured ControlNet folder used to
        // leave a stale link in place and produce an identical hash, so the
        // pipeline already loaded from the old folder was reused indefinitely.
        // Only two stat calls, against reloading a multi-gigabyte pipeline.
        var effectiveControlNetLocation: String?
        if !controlNet.isEmpty {
            effectiveControlNetLocation = ControlNetLink.resolve(
                configured: controlNetDirectory,
                in: model.url
            )
        }

        var hasher = Hasher()
        hasher.combine(model)
        hasher.combine(controlNet)
        hasher.combine(effectiveControlNetLocation)
        hasher.combine(computeUnit)
        hasher.combine(reduceMemory)
        let hash = hasher.finalize()
        guard hash != currentPipelineHash else { return }

        session.emit(.state(.loading(nil)))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnit

        switch model.type {
        case .sdxl:
            pipeline = try StableDiffusionXLPipeline(
                resourcesAt: model.url,
                configuration: configuration,
                reduceMemory: reduceMemory
            )
        case .sd3:
            pipeline = try StableDiffusion3Pipeline(
                resourcesAt: model.url,
                configuration: configuration,
                reduceMemory: reduceMemory
            )
        case .sd15:
            pipeline = try StableDiffusionPipeline(
                resourcesAt: model.url,
                controlNet: controlNet,
                configuration: configuration,
                disableSafety: true,
                reduceMemory: reduceMemory
            )
        }

        currentPipelineHash = hash
    }

    private func generate(
        _ config: CoreMLGenerationConfig,
        request: GenerationRequest,
        session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws {
        guard let pipeline else {
            throw GenerationError.pipelineNotAvailable
        }
        session.emit(.state(.loading(nil)))

        var pipelineConfig = StableDiffusionPipeline.Configuration(prompt: config.prompt)
        pipelineConfig.negativePrompt = config.negativePrompt
        pipelineConfig.seed = config.seed
        pipelineConfig.startingImage = config.startingImage
        pipelineConfig.strength = config.strength
        pipelineConfig.stepCount = config.stepCount
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
        sdi.engine = config.model.id.engine.rawValue
        sdi.modelKey = config.model.id.key
        sdi.scheduler = config.scheduler
        sdi.mlComputeUnit = config.mlComputeUnit
        sdi.steps = pipelineConfig.stepCount
        sdi.guidanceScale = Double(pipelineConfig.guidanceScale)

        let useDenoisedIntermediates = pipelineConfig.useDenoisedIntermediates
        for _ in 0..<config.numberOfImages {
            let images = try pipeline.generateImages(configuration: pipelineConfig) { progress in
                // Synchronous, unlike the `Task { await onProgress(…) }` this
                // replaces. Each of those was a separate unstructured task, so
                // two progress updates could be applied out of order, and a task
                // created during teardown could outlive the request. Emitting
                // into the session's stream preserves order and is dropped at one
                // checkpoint once the session closes.
                session.emit(
                    .progress(
                        GenerationState.Progress(
                            step: progress.step,
                            stepCount: progress.stepCount
                        )
                    )
                )
                if useDenoisedIntermediates {
                    session.emit(.preview(progress.currentImages.last.flatMap { $0 }))
                }
                return !session.isCancelled
            }
            if session.isCancelled {
                break
            }
            for image in images {
                guard let image else { continue }
                sdi.image = image
                sdi.aspectRatio = CGFloat(Double(image.width) / Double(image.height))
                sdi.id = UUID()
                sdi.seed = pipelineConfig.seed
                sdi.generatedDate = Date.now
                sdi.path = ""
                sdi.startingImage = config.startingImageName
                sdi.controlNetImage = config.controlNetImageName
                sdi.inputImages = config.inputImageNames

                let type = UTType.fromString(config.imageType)
                guard
                    let data = await sdi.imageData(type, metadataFields: request.metadataFields)
                else { continue }
                let metadata = GenerationMetadata(
                    prompt: sdi.prompt,
                    negativePrompt: sdi.negativePrompt,
                    width: image.width,
                    height: image.height,
                    model: sdi.model,
                    engine: sdi.engine,
                    modelKey: sdi.modelKey,
                    quality: sdi.quality,
                    startingImage: config.startingImageName,
                    controlNetImage: config.controlNetImageName,
                    inputImages: config.inputImageNames,
                    scheduler: sdi.scheduler,
                    mlComputeUnit: request.mlComputeUnit,
                    seed: sdi.seed,
                    steps: sdi.steps,
                    guidanceScale: sdi.guidanceScale,
                    generatedDate: sdi.generatedDate,
                    metadataFields: request.metadataFields
                )
                try await onResult(GenerationResult(metadata: metadata, imageData: data))
            }
            pipelineConfig.seed += 1
        }
    }

    private func makeConfig(
        from request: GenerationRequest,
        payload: CoreMLGenerationPayload
    ) -> CoreMLGenerationConfig {
        let model = payload.model
        var startingImage: CGImage?
        var controlNetInputs: [CGImage] = []
        var resolvedControlNets: [String] = []

        if let size = model.inputSize {
            if let data = request.startingImageData {
                startingImage = CGImage.fromData(data)?.scaledAndCroppedTo(size: size)
            }

            for (name, data) in zip(request.controlNetNames, request.controlNetImageData) {
                guard let image = CGImage.fromData(data)?.scaledAndCroppedTo(size: size) else {
                    continue
                }
                controlNetInputs.append(image)
                resolvedControlNets.append(name)
            }
        }

        return CoreMLGenerationConfig(
            prompt: request.prompt,
            negativePrompt: request.negativePrompt,
            startingImage: startingImage,
            startingImageName: request.startingImageName ?? "",
            controlNetImageName: request.controlNetImageNames.first ?? "",
            inputImageNames: request.inputImageNames,
            controlNetInputs: controlNetInputs,
            model: model,
            mlComputeUnit: payload.computeUnit,
            controlNets: resolvedControlNets,
            strength: request.strength,
            stepCount: request.stepCount,
            guidanceScale: request.guidanceScale,
            disableSafety: payload.disableSafety,
            scheduler: request.scheduler,
            useDenoisedIntermediates: request.useDenoisedIntermediates,
            seed: request.seed,
            numberOfImages: request.numberOfImages,
            imageType: request.imageType
        )
    }
}
