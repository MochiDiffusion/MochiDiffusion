//
//  LocalEngines.swift
//  Mochi Diffusion
//

import CoreML
import Foundation

/// Core ML Stable Diffusion: models converted with Apple's `ml-stable-diffusion`,
/// each a directory of `.mlmodelc` bundles.
nonisolated struct CoreMLStableDiffusionEngine: GenerationEngineDescriptor {
    typealias Model = SDModel
    typealias Payload = CoreMLGenerationPayload

    static let id = EngineID.coreMLStableDiffusion
    var displayName: String { "Core ML Stable Diffusion" }

    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard fileSystem.fileExists(settings.modelDirectory) else {
            return .unreachable(
                String(
                    localized: "Models folder not found",
                    comment: "Engine unavailable because its models folder is missing"
                )
            )
        }
        return .ready
    }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [SDModel] {
        let controlNets = controlNets(in: context.settings.controlNetDirectory)
        return try context.localModelDirectories()
            .compactMap { url in
                SDModel(
                    url: url,
                    name: ModelID.localKey(for: url),
                    controlNet: hasControlNet(url) ? controlNets : []
                )
            }
    }

    func plan(draft: GenerationDraft, model: SDModel) throws
        -> GenerationPlan<CoreMLGenerationPayload>
    {
        // Every value the model will actually use, resolved here and nowhere
        // else. A fixed-size model overrides the sidebar's size; a persisted
        // guidance scale from another model is clamped rather than rejected.
        let constraints = model.constraints
        let size = constraints.size.resolved(draft.configuredSize)
        let stepCount = constraints.steps.resolved(draft.stepCount)
        let scheduler = constraints.scheduler.resolved(draft.scheduler)
        let strength = constraints.startingImage.strength
            .resolved(Double(draft.strength))
            .map(Float.init)
        let guidanceScale = constraints.guidanceScale
            .resolved(Double(draft.guidanceScale))
            .map(Float.init)
        let numberOfImages =
            constraints.numberOfImages.resolved(draft.numberOfImages) ?? draft.numberOfImages
        let quality = constraints.quality.resolved(draft.quality)
        let computeUnit = draft.computeUnitPreference.computeUnits(forModel: model)

        var controlNetNames: [String] = []
        var controlNetImageNames: [String] = []
        var controlNetInputs: [Data] = []
        // Said as a constraint now, so the sidebar hides the control instead of
        // this quietly dropping what the user put in it. A freeform model has no
        // fixed size to scale guide images to, and `SDModel` reports no matching
        // nets for one, so its constraint is `.unsupported`.
        if constraints.controlNet.isSupported {
            for controlNet in draft.controlNets {
                guard
                    let name = controlNet.name,
                    let image = controlNet.image,
                    let data = image.scaledAndCroppedTo(size: size)?.pngData()
                else { continue }
                controlNetNames.append(name)
                controlNetInputs.append(data)
                if let imageName = controlNet.imageName?.normalizedFilename {
                    controlNetImageNames.append(imageName)
                }
            }
        }

        return GenerationPlan<CoreMLGenerationPayload>(
            payload: CoreMLGenerationPayload(
                model: model,
                computeUnit: computeUnit,
                reduceMemory: draft.reduceMemory,
                disableSafety: !draft.safetyChecker,
                controlNetDirectory: draft.controlNetDirectory,
                strength: strength ?? draft.strength,
                guidanceScale: guidanceScale ?? draft.guidanceScale,
                stepCount: stepCount ?? draft.stepCount,
                scheduler: scheduler ?? draft.scheduler
            ),
            size: size,
            startingImageData: draft.startingImage?.scaledAndCroppedTo(size: size)?.pngData(),
            controlNetImageData: controlNetInputs,
            controlNetNames: controlNetNames,
            controlNetImageNames: controlNetImageNames,
            stepCount: stepCount,
            scheduler: scheduler,
            strength: strength,
            guidanceScale: guidanceScale,
            quality: quality,
            numberOfImages: numberOfImages,
            mlComputeUnit: computeUnit,
            startingImageName: draft.startingImageName?.normalizedFilename,
            inputImageNames: []
        )
    }

    /// Matches on the model name's prefix before the first underscore and on
    /// orientation, which is how converted sets are named in practice —
    /// `foo_512x768` beside `foo_768x512`.
    ///
    /// A naming heuristic, deliberately kept inside the engine: how one engine's
    /// model files are named is not something the sidebar should know.
    func model(forSize size: CGSize, among candidates: [SDModel], current: SDModel) -> SDModel? {
        func orientation(width: Double, height: Double) -> Int {
            if width > height { return 1 }
            if width < height { return -1 }
            return 0
        }

        let wanted = orientation(width: size.width, height: size.height)
        let prefix = current.name.split(separator: "_").first
        return candidates.first { candidate in
            guard
                candidate.name.split(separator: "_").first == prefix,
                let candidateSize = candidate.inputSize
            else { return false }
            return orientation(width: candidateSize.width, height: candidateSize.height) == wanted
        }
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        CoreMLEngineRuntime()
    }

    private func hasControlNet(_ url: URL) -> Bool {
        fileSystem.fileExists(url.appending(components: "ControlledUnet.mlmodelc", "metadata.json"))
    }

    private func controlNets(in directory: URL) -> [SDControlNet] {
        guard fileSystem.fileExists(directory),
            let contents = try? fileSystem.contentsOfDirectory(at: directory)
        else {
            return []
        }
        return contents.compactMap { SDControlNet(url: $0) }
    }
}

/// Iris: FLUX.2 and Z-Image models in diffusers layout, run through the bundled
/// Iris library.
nonisolated struct IrisEngine: GenerationEngineDescriptor {
    typealias Model = IrisFluxKleinModel
    typealias Payload = IrisGenerationPayload

    static let id = EngineID.iris
    var displayName: String { "Iris" }

    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard fileSystem.fileExists(settings.modelDirectory) else {
            return .unreachable(
                String(
                    localized: "Models folder not found",
                    comment: "Engine unavailable because its models folder is missing"
                )
            )
        }
        return .ready
    }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [IrisFluxKleinModel] {
        try context.localModelDirectories()
            .compactMap { IrisFluxKleinModel(url: $0, name: ModelID.localKey(for: $0)) }
    }

    func plan(draft: GenerationDraft, model: IrisFluxKleinModel) throws
        -> GenerationPlan<IrisGenerationPayload>
    {
        // Read from the model's constraints, which is the same declaration the
        // sidebar reads, so the field it shows and the value used here cannot
        // disagree.
        let constraints = model.constraints
        let size = constraints.size.resolved(draft.configuredSize)
        let stepCount = constraints.steps.resolved(draft.stepCount)
        let scheduler = constraints.scheduler.resolved(draft.scheduler)
        let numberOfImages =
            constraints.numberOfImages.resolved(draft.numberOfImages) ?? draft.numberOfImages

        return GenerationPlan<IrisGenerationPayload>(
            payload: IrisGenerationPayload(
                modelDirectory: model.url.path(percentEncoded: false),
                stepCount: stepCount ?? draft.stepCount,
                scheduler: scheduler ?? draft.scheduler
            ),
            size: size,
            startingImageData: draft.startingImage?.scaledAndCroppedTo(size: size)?.pngData(),
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            stepCount: stepCount,
            scheduler: scheduler,
            // Klein ignores both: a distilled model has no guidance, and a
            // starting image is an input image rather than a denoising origin.
            strength: constraints.startingImage.strength.resolved(Double(draft.strength))
                .map(Float.init),
            guidanceScale: constraints.guidanceScale.resolved(Double(draft.guidanceScale))
                .map(Float.init),
            numberOfImages: numberOfImages,
            mlComputeUnit: nil,
            // Iris records what it was given as an input image rather than as a
            // starting image, so the same sidebar state lands in a different field.
            startingImageName: nil,
            inputImageNames: draft.startingImageName?.normalizedFilename.map { [$0] } ?? []
        )
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        IrisEngineRuntime()
    }

}

/// What Core ML Stable Diffusion needs beyond the values every engine reports.
nonisolated struct CoreMLGenerationPayload: Sendable {
    let model: SDModel
    let computeUnit: MLComputeUnits
    let reduceMemory: Bool
    let disableSafety: Bool
    /// Carried so the runtime can link the bundles into the model directory when
    /// it is about to load a ControlNet pipeline, rather than discovery doing it
    /// for every model on every folder-change event.
    let controlNetDirectory: URL
    /// Resolved, and non-optional, because Core ML always uses all four. The
    /// request carries them as optionals for the queue's benefit; the runtime
    /// wants the values it will actually pass to the pipeline.
    let strength: Float
    let guidanceScale: Float
    let stepCount: Int
    let scheduler: Scheduler
}

/// Iris loads from a directory rather than a typed model handle.
nonisolated struct IrisGenerationPayload: Sendable {
    let modelDirectory: String
    /// Resolved, and non-optional, for the same reason Core ML's are. Iris uses
    /// the step count directly as `params.num_steps`; the scheduler it only
    /// records, since flow matching is fixed inside the C library.
    let stepCount: Int
    let scheduler: Scheduler
}
