//
//  GenerationRequest.swift
//  Mochi Diffusion
//

import CoreML
import Foundation

/// A queued generation, resolved.
///
/// Engine-specific values live in `payload`, produced by that engine's
/// `plan`; everything the queue and gallery need is a plain field, so neither has
/// to know which engine produced the request.
///
/// Nothing is renegotiated after `plan`: the values here are the ones that will be
/// used and recorded. A runtime that substituted its own would put the queue and
/// the saved image out of step with each other.
nonisolated struct GenerationRequest: Sendable, Identifiable {
    let id = UUID()

    let modelID: ModelID
    /// The model's name, for the queue. A plain field rather than something
    /// derived from `payload`, so the queue never has to know which engine
    /// produced the request.
    let displayName: String
    let metadataFields: Set<MetadataField>

    /// Engine-typed, produced by `GenerationEngineDescriptor.plan(draft:model:)`.
    ///
    /// The one concession in this design: the queue is heterogeneous, so the
    /// payload's type is erased and the owning generator downcasts it. A mismatch
    /// is an internal invariant failure naming both ids, never a user-facing
    /// configuration error. Neither the queue UI nor the gallery may look inside.
    let payload: any Sendable

    let prompt: String
    let negativePrompt: String
    /// The size that will actually be produced, not necessarily the one typed
    /// into the sidebar — a Core ML model with a fixed input size overrides it.
    let size: CGSize

    let startingImageData: Data?
    let startingImageName: String?
    /// Scaled guide images, alongside `startingImageData` rather than inside the
    /// payload: the queue shows them as thumbnails and restores them to the
    /// sidebar, and duplicating them in both places would be worse than one
    /// field only one engine currently fills.
    let controlNetImageData: [Data]
    let controlNetNames: [String]
    let controlNetImageNames: [String]
    let inputImageNames: [String]

    /// Resolved by `plan`; `nil` when the model does not use it at all, so the
    /// queue can leave the row out rather than print a number that had no effect.
    let strength: Float?
    let stepCount: Int
    /// Resolved by `plan`; `nil` when the model does not use it at all, so the
    /// queue can leave the row out rather than print a number that had no effect.
    let guidanceScale: Float?
    let scheduler: Scheduler
    /// Core ML only, but the queue displays it when the model records it, so it
    /// stays a plain field rather than something the queue has to unwrap a
    /// payload for. Becomes an engine-provided display detail once engines
    /// describe their own metadata rows.
    let mlComputeUnit: MLComputeUnits?
    let useDenoisedIntermediates: Bool
    let seed: UInt32
    let numberOfImages: Int
    let imageDir: String
    let imageType: String
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
    let model: String
    let engine: String
    let modelKey: String
    let quality: String
    let startingImage: String
    let controlNetImage: String
    let inputImages: [String]
    let scheduler: Scheduler
    let mlComputeUnit: MLComputeUnits?
    let seed: UInt32
    let steps: Int
    let guidanceScale: Double
    let generatedDate: Date
    let metadataFields: Set<MetadataField>
}
