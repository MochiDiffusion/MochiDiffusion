//
//  GenerationRequest.swift
//  Mochi Diffusion
//

import CoreML
import Foundation

nonisolated enum IrisModelFamily: Sendable {
    case fluxKlein
    case zImageTurbo

    var fallbackDisplayName: String {
        switch self {
        case .fluxKlein:
            return "Iris FLUX.2"
        case .zImageTurbo:
            return "Iris Z-Image-Turbo"
        }
    }

    var generationCapabilities: GenerationCapabilities {
        switch self {
        case .fluxKlein:
            return IrisFluxKleinModel.generationCapabilities
        case .zImageTurbo:
            return []
        }
    }

    var metadataFields: Set<MetadataField> {
        switch self {
        case .fluxKlein:
            return IrisFluxKleinModel.metadataFields
        case .zImageTurbo:
            return []
        }
    }

    func effectiveStepCount(requestedStepCount: Int) -> Int? {
        switch self {
        case .fluxKlein:
            return 4
        case .zImageTurbo:
            return requestedStepCount
        }
    }

    func effectiveScheduler(requestedScheduler: Scheduler) -> Scheduler? {
        switch self {
        case .fluxKlein:
            return .discreteFlowScheduler
        case .zImageTurbo:
            return requestedScheduler
        }
    }
}

nonisolated enum GenerationPipeline: Sendable {
    case sd(
        model: SDModel,
        computeUnit: MLComputeUnits,
        controlNets: [String],
        reduceMemory: Bool
    )
    case iris(modelDir: String, family: IrisModelFamily)

    var displayName: String {
        switch self {
        case .sd(let model, _, _, _):
            return model.name
        case .iris(let modelDir, let family):
            let url = URL(fileURLWithPath: modelDir)
            return url.lastPathComponent.isEmpty
                ? family.fallbackDisplayName
                : url.lastPathComponent
        }
    }

    var coreMLModel: SDModel? {
        switch self {
        case .sd(let model, _, _, _):
            return model
        case .iris:
            return nil
        }
    }

    var mlComputeUnit: MLComputeUnits? {
        switch self {
        case .sd(_, let computeUnit, _, _):
            return computeUnit
        case .iris:
            return nil
        }
    }

    var controlNets: [String] {
        switch self {
        case .sd(_, _, let controlNets, _):
            return controlNets
        case .iris:
            return []
        }
    }

    var reduceMemory: Bool {
        switch self {
        case .sd(_, _, _, let reduceMemory):
            return reduceMemory
        case .iris:
            return false
        }
    }

    var generationCapabilities: GenerationCapabilities {
        switch self {
        case .sd(let model, _, _, _):
            return model.config.generationCapabilities
        case .iris(_, let family):
            return family.generationCapabilities
        }
    }

    /// Metadata keys this pipeline persists into image metadata on export.
    var metadataFields: Set<MetadataField> {
        switch self {
        case .sd(let model, _, _, _):
            return model.config.metadataFields
        case .iris(_, let family):
            return family.metadataFields
        }
    }

    /// Pipeline-resolved step count for UI that should display effective runtime values.
    func effectiveStepCount(requestedStepCount: Int) -> Int? {
        guard metadataFields.contains(.steps) else { return nil }
        switch self {
        case .sd:
            return requestedStepCount
        case .iris(_, let family):
            return family.effectiveStepCount(requestedStepCount: requestedStepCount)
        }
    }

    /// Pipeline-resolved scheduler for UI that should display effective runtime values.
    func effectiveScheduler(requestedScheduler: Scheduler) -> Scheduler? {
        guard metadataFields.contains(.scheduler) else { return nil }
        switch self {
        case .sd:
            return requestedScheduler
        case .iris(_, let family):
            return family.effectiveScheduler(requestedScheduler: requestedScheduler)
        }
    }
}

nonisolated struct GenerationRequest: Sendable, Identifiable {
    let id: UUID
    let pipeline: GenerationPipeline

    let prompt: String
    let negativePrompt: String
    let size: CGSize

    let startingImageData: Data?
    let startingImageName: String?
    let controlNetInputs: [Data]
    let controlNetImageNames: [String]
    let inputImageNames: [String]

    let strength: Float
    let stepCount: Int
    let guidanceScale: Float
    let disableSafety: Bool
    let scheduler: Scheduler
    let useDenoisedIntermediates: Bool
    let seed: UInt32
    let numberOfImages: Int
    let imageDir: String
    let imageType: String

    init(
        id: UUID = UUID(),
        pipeline: GenerationPipeline,
        prompt: String,
        negativePrompt: String,
        size: CGSize,
        startingImageData: Data?,
        startingImageName: String?,
        controlNetInputs: [Data],
        controlNetImageNames: [String],
        inputImageNames: [String],
        strength: Float,
        stepCount: Int,
        guidanceScale: Float,
        disableSafety: Bool,
        scheduler: Scheduler,
        useDenoisedIntermediates: Bool,
        seed: UInt32,
        numberOfImages: Int,
        imageDir: String,
        imageType: String
    ) {
        self.id = id
        self.pipeline = pipeline
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.size = size
        self.startingImageData = startingImageData
        self.startingImageName = startingImageName
        self.controlNetInputs = controlNetInputs
        self.controlNetImageNames = controlNetImageNames
        self.inputImageNames = inputImageNames
        self.strength = strength
        self.stepCount = stepCount
        self.guidanceScale = guidanceScale
        self.disableSafety = disableSafety
        self.scheduler = scheduler
        self.useDenoisedIntermediates = useDenoisedIntermediates
        self.seed = seed
        self.numberOfImages = numberOfImages
        self.imageDir = imageDir
        self.imageType = imageType
    }
}

nonisolated struct GenerationResult: Sendable, Identifiable {
    let id: UUID
    let metadata: GenerationMetadata
    let imageData: Data
    let imageURL: URL?

    init(
        id: UUID = UUID(),
        metadata: GenerationMetadata,
        imageData: Data,
        imageURL: URL? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.imageData = imageData
        self.imageURL = imageURL
    }
}

nonisolated struct GenerationMetadata: Sendable {
    let prompt: String
    let negativePrompt: String
    let width: Int
    let height: Int
    let pipeline: GenerationPipeline
    let model: String
    let quality: String
    let startingImage: String
    let controlNetImage: String
    let inputImages: [String]
    let scheduler: Scheduler
    let seed: UInt32
    let steps: Int
    let guidanceScale: Double
    let generatedDate: Date
    let metadataFields: Set<MetadataField>
}
