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

    func discoverModels(_ settings: EngineSettings) async throws -> [SDModel] {
        let controlNets = controlNets(in: settings.controlNetDirectory)
        return try fileSystem.subDirectories(in: settings.modelDirectory)
            .compactMap { url in
                linkControlNetDirectoryIfNeeded(
                    for: url, controlNetDir: settings.controlNetDirectory)
                return SDModel(
                    url: url,
                    name: ModelID.localKey(for: url),
                    controlNet: hasControlNet(url) ? controlNets : []
                )
            }
    }

    func plan(draft: GenerationDraft, model: SDModel) throws -> GenerationPlan {
        // A fixed-size model produces its own size whatever the sidebar says, and
        // every image handed to it has to match.
        let size = model.inputSize ?? draft.configuredSize

        var controlNetNames: [String] = []
        var controlNetImageNames: [String] = []
        var controlNetInputs: [Data] = []
        // ControlNet needs a fixed input size to scale its guide images to, so a
        // freeform model gets none. Phase 4 should say this as an unsupported
        // constraint that hides the control, rather than accepting the input and
        // dropping it here.
        if model.inputSize != nil {
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

        return GenerationPlan(
            payload: CoreMLGenerationPayload(
                model: model,
                computeUnit: draft.computeUnitPreference.computeUnits(forModel: model),
                reduceMemory: draft.reduceMemory,
                disableSafety: !draft.safetyChecker
            ),
            size: size,
            startingImageData: draft.startingImage?.scaledAndCroppedTo(size: size)?.pngData(),
            controlNetImageData: controlNetInputs,
            controlNetNames: controlNetNames,
            controlNetImageNames: controlNetImageNames,
            stepCount: draft.stepCount,
            scheduler: draft.scheduler,
            mlComputeUnit: draft.computeUnitPreference.computeUnits(forModel: model),
            startingImageName: draft.startingImageName?.normalizedFilename,
            inputImageNames: []
        )
    }

    private func hasControlNet(_ url: URL) -> Bool {
        fileSystem.fileExists(url.appending(components: "ControlledUnet.mlmodelc", "metadata.json"))
    }

    /// A ControlNet-capable model needs the ControlNet bundles reachable from
    /// inside its own directory, so discovery drops a symlink in.
    ///
    /// A write during discovery is a side effect that does not belong on a read
    /// path — it fires on every folder-change event, and it mutates the user's
    /// models folder. Preserved as-is here because this step is a refactor;
    /// pipeline loading is where it belongs, which is the runtime's job in Phase 3.
    private func linkControlNetDirectoryIfNeeded(for url: URL, controlNetDir: URL) {
        guard hasControlNet(url) else { return }
        let link = url.appending(component: "controlnet")
        guard !fileSystem.fileExists(link) else { return }
        try? FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: controlNetDir.path(percentEncoded: false)
        )
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

    func discoverModels(_ settings: EngineSettings) async throws -> [IrisFluxKleinModel] {
        try fileSystem.subDirectories(in: settings.modelDirectory)
            .compactMap { IrisFluxKleinModel(url: $0, name: ModelID.localKey(for: $0)) }
    }

    func plan(draft: GenerationDraft, model: IrisFluxKleinModel) throws -> GenerationPlan {
        // FLUX.2 Klein is a distilled model: four steps on the flow-match
        // scheduler, whatever the sidebar offers. This used to live in
        // IrisModelFamily.effectiveStepCount, consulted by the queue for display
        // while the request still carried the user's number and the generator
        // hardcoded its own — three places to disagree. Resolving it here means
        // the request, the queue and the saved metadata all read the same value.
        // Phase 4 turns it into a pinned constraint so the sidebar stops offering
        // an editable field in the first place.
        let size = draft.configuredSize

        return GenerationPlan(
            payload: IrisGenerationPayload(
                modelDirectory: model.url.path(percentEncoded: false)
            ),
            size: size,
            startingImageData: draft.startingImage?.scaledAndCroppedTo(size: size)?.pngData(),
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            stepCount: Self.distilledStepCount,
            scheduler: .discreteFlowScheduler,
            mlComputeUnit: nil,
            // Iris records what it was given as an input image rather than as a
            // starting image, so the same sidebar state lands in a different field.
            startingImageName: nil,
            inputImageNames: draft.startingImageName?.normalizedFilename.map { [$0] } ?? []
        )
    }

    static let distilledStepCount = 4
}

/// What Core ML Stable Diffusion needs beyond the values every engine reports.
nonisolated struct CoreMLGenerationPayload: Sendable {
    let model: SDModel
    let computeUnit: MLComputeUnits
    let reduceMemory: Bool
    let disableSafety: Bool
}

/// Iris loads from a directory rather than a typed model handle.
nonisolated struct IrisGenerationPayload: Sendable {
    let modelDirectory: String
}
