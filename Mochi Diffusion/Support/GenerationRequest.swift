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
    /// The model's name, for the queue.
    let displayName: String
    let metadataFields: Set<MetadataField>

    /// Engine-typed, produced by `GenerationEngineDescriptor.plan(draft:model:)`.
    ///
    /// The queue is heterogeneous, so the type is erased here and the owning runtime
    /// downcasts it. Neither the queue UI nor the gallery may look inside.
    let payload: any Sendable

    let prompt: String
    let negativePrompt: String
    /// The size that will actually be produced, not necessarily the one typed
    /// into the sidebar — a Core ML model with a fixed input size overrides it.
    let size: CGSize

    let startingImageData: Data?
    let startingImageName: String?
    /// Scaled guide images. Here rather than in the payload because the queue shows
    /// them as thumbnails and restores them to the sidebar.
    let controlNetImageData: [Data]
    let controlNetNames: [String]
    let controlNetImageNames: [String]
    let inputImageNames: [String]

    /// Resolved by `plan`; `nil` when the model does not use it at all, so the
    /// queue can leave the row out rather than print a number that had no effect.
    let strength: Float?
    /// Resolved by `plan`; `nil` when the model does not use it at all.
    ///
    /// Optional for the same reason `strength` is, and specifically so a hosted
    /// engine is not forced to invent a step count or a sampler it has no concept
    /// of. Runtimes that use these take them from their own payload.
    let stepCount: Int?
    /// Resolved by `plan`; `nil` when the model does not use it at all, so the
    /// queue can leave the row out rather than print a number that had no effect.
    let guidanceScale: Float?
    /// Resolved by `plan`; `nil` when the model does not use it at all. See
    /// `stepCount`.
    let scheduler: Scheduler?
    /// Resolved by `plan`; `nil` for every model that has no notion of quality,
    /// which is both local engines.
    let quality: ImageQuality?
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
    /// Which request produced this, so applying it late cannot disturb state the
    /// next request already owns — the in-progress preview in particular.
    ///
    /// Not part of `GenerationMetadata`: that is the contract written into the
    /// image, and a request id means nothing once the file is on disk. Attached by
    /// `GenerationService`, which knows the request, so a runtime does not have to
    /// remember to.
    let requestID: GenerationRequest.ID?

    init(
        id: UUID = UUID(),
        metadata: GenerationMetadata,
        imageData: Data,
        imageURL: URL? = nil,
        requestID: GenerationRequest.ID? = nil
    ) {
        self.id = id
        self.metadata = metadata
        self.imageData = imageData
        self.imageURL = imageURL
        self.requestID = requestID
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
