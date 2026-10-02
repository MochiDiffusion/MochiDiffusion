//
//  GenerationError.swift
//  Mochi Diffusion
//

/// Failures in the generation pipeline that are not specific to one engine.
nonisolated enum GenerationError: Error, Equatable {
    case imageDirectoryNoAccess
    /// The runtime went quiet for longer than its `idleTimeout` and the queue
    /// stopped waiting. Distinct from cancellation, which is the user's doing.
    case requestExpired
    case pipelineNotAvailable
    case requestedModelNotFound
    /// The image or its metadata record could not be encoded, so the image was
    /// not saved. An image is never saved without its record.
    case imageEncodingFailed

    /// An engine's response was not shaped the way its protocol documents, such
    /// as an image that would not decode.
    case malformedResponse
}
