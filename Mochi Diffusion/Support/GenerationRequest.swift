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

    /// A scaled denoising origin. Separate from references so an unnamed starting
    /// image remains a starting image when this request is copied back.
    let startingImageData: Data?
    /// Scaled reference images, in the order the engine will use them. Here rather
    /// than in the payload because the queue shows them as thumbnails and restores
    /// them to the sidebar.
    let inputImageData: [Data]
    /// The starting image's source filename, when it had one.
    let startingImageName: String?
    /// Scaled guide images. Here rather than in the payload because the queue shows
    /// them as thumbnails and restores them to the sidebar.
    let controlNetImageData: [Data]
    let controlNetNames: [String]
    /// Positionally aligned with `controlNetImageData`; nil means the guide had
    /// no source filename.
    let controlNetImageNames: [String?]
    /// Positionally aligned with `inputImageData`; nil means the corresponding
    /// reference had no source filename.
    let inputImageNames: [String?]

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
    /// is a plain field rather than something the queue has to unwrap a payload
    /// for.
    let mlComputeUnit: MLComputeUnits?
    let useDenoisedIntermediates: Bool
    let seed: UInt32
    let numberOfImages: Int
    let imageDir: String
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

/// What one generated image records: the settings that produced it.
///
/// A runtime builds one per output image, from the values that reached the
/// pipeline. A value is `nil` when the model does not use that option or the
/// engine does not report it. Nothing here is filled with a default.
nonisolated struct GenerationMetadata: Sendable {
    let prompt: String
    /// `nil` when the model takes no negative prompt.
    let negativePrompt: String?
    let width: Int
    let height: Int
    let model: String
    let engine: String
    let modelKey: String
    /// The model's architecture or family, such as `SDXL` or `FLUX.2 Klein`.
    let architecture: String?
    let quality: String?
    /// The starting image's filename. Empty when the image had none; `nil`
    /// when no starting image was used.
    let startingImage: String?
    /// Starting-image strength. Only an image generated from a starting image
    /// has one.
    let strength: Double?
    /// The ControlNet model that ran, if any.
    let controlNet: String?
    /// The guide image's filename. Empty when the image had none; `nil` when
    /// no ControlNet ran.
    let controlNetImage: String?
    /// Reference images in the order the engine used them, with an empty name
    /// for a reference that had no filename. `nil` when the model takes none.
    let inputImages: [String]?
    let scheduler: Scheduler?
    let mlComputeUnit: MLComputeUnits?
    let seed: UInt32?
    let steps: Int?
    let guidanceScale: Double?
    let generatedDate: Date
    let metadataFields: Set<MetadataField>
}
