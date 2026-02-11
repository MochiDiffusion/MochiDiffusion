//
//  GenerationRequest.swift
//  Mochi Diffusion
//

import CoreML
import Foundation

enum GenerationPipeline: Sendable {
    case sd(
        model: SDModel,
        computeUnit: MLComputeUnits,
        controlNets: [String],
        reduceMemory: Bool
    )
    case flux2c(modelDir: String)

    var displayName: String {
        switch self {
        case .sd(let model, _, _, _):
            return model.name
        case .flux2c(let modelDir):
            let url = URL(fileURLWithPath: modelDir)
            return url.lastPathComponent.isEmpty ? "FLUX.2" : url.lastPathComponent
        }
    }

    var coreMLModel: SDModel? {
        switch self {
        case .sd(let model, _, _, _):
            return model
        case .flux2c:
            return nil
        }
    }

    var mlComputeUnit: MLComputeUnits? {
        switch self {
        case .sd(_, let computeUnit, _, _):
            return computeUnit
        case .flux2c:
            return nil
        }
    }

    var controlNets: [String] {
        switch self {
        case .sd(_, _, let controlNets, _):
            return controlNets
        case .flux2c:
            return []
        }
    }

    var reduceMemory: Bool {
        switch self {
        case .sd(_, _, _, let reduceMemory):
            return reduceMemory
        case .flux2c:
            return false
        }
    }

    var generationCapabilities: GenerationCapabilities {
        switch self {
        case .sd(let model, _, _, _):
            return model.config.generationCapabilities
        case .flux2c:
            return Flux2cModel.generationCapabilities
        }
    }

    /// Metadata keys this pipeline persists into image metadata on export.
    var metadataFields: Set<MetadataField> {
        switch self {
        case .sd(let model, _, _, _):
            return model.config.metadataFields
        case .flux2c:
            return Flux2cModel.metadataFields
        }
    }

    /// Pipeline-resolved step count for UI that should display effective runtime values.
    func effectiveStepCount(requestedStepCount: Int) -> Int? {
        guard metadataFields.contains(.steps) else { return nil }
        switch self {
        case .sd:
            return requestedStepCount
        case .flux2c:
            return 4
        }
    }

    /// Pipeline-resolved scheduler for UI that should display effective runtime values.
    func effectiveScheduler(requestedScheduler: Scheduler) -> Scheduler? {
        guard metadataFields.contains(.scheduler) else { return nil }
        switch self {
        case .sd:
            return requestedScheduler
        case .flux2c:
            return .discreteFlowScheduler
        }
    }
}

struct GenerationRequest: Sendable, Identifiable {
    let id: UUID
    let pipeline: GenerationPipeline

    let prompt: String
    let negativePrompt: String
    let size: CGSize

    let startingImageData: Data?
    let controlNetInputs: [Data]

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
        controlNetInputs: [Data],
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
        self.controlNetInputs = controlNetInputs
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

struct GenerationResult: Sendable, Identifiable {
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

struct GenerationMetadata: Sendable {
    let prompt: String
    let negativePrompt: String
    let width: Int
    let height: Int
    let pipeline: GenerationPipeline
    let model: String
    let scheduler: Scheduler
    let seed: UInt32
    let steps: Int
    let guidanceScale: Double
    let generatedDate: Date
    let metadataFields: Set<MetadataField>
}
