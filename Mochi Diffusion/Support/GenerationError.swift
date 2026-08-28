//
//  GenerationError.swift
//  Mochi Diffusion
//

import Foundation

/// Failures in the generation pipeline that are not specific to one engine.
///
/// Previously nested in `SDImageGenerator` while being thrown and caught by the
/// queue, the controller and model discovery — none of which are Core ML. Lifted
/// out so a hosted engine does not have to reach into a local engine's namespace
/// to report that the images folder is unwritable.
nonisolated enum GenerationError: Error, Equatable {
    case imageDirectoryNoAccess
    /// The runtime went quiet for longer than its `idleTimeout` and the queue
    /// stopped waiting. Distinct from cancellation, which is the user's doing,
    /// and reported honestly: a remote service may still finish and bill for work
    /// we stopped waiting for.
    case requestExpired
    case modelDirectoryNoAccess
    case modelSubDirectoriesNoAccess
    case noModelsFound
    case pipelineNotAvailable
    case requestedModelNotFound

    // MARK: - Hosted engines

    /// No credential, or one the service rejected.
    case authenticationFailed
    /// Asked to slow down. Not fatal to the queue: the next request may succeed.
    case rateLimited
    /// The service answered, unhappily. Carries what it said, because a hosted
    /// failure the user cannot see the text of is one they cannot act on.
    case serviceFailure(String)
    /// The response was not shaped the way the API documents.
    case malformedResponse
    /// The service declined to make the image on content-policy grounds.
    ///
    /// An `Error` because it ends the request, but **not** an error the user sees
    /// as one: the call succeeded and the service told us something. The queue
    /// reports it through `.ready(message)`, the same channel as "Couldn't load
    /// <model>", rather than the red banner an `.error` produces. See D5 of
    /// `Multi-Engine-Design.md`.
    case refused(String)
}
