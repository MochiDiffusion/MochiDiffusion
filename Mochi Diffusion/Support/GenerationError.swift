//
//  GenerationError.swift
//  Mochi Diffusion
//

import Foundation

/// Failures in the generation pipeline that are not specific to one engine.
nonisolated enum GenerationError: Error, Equatable {
    case imageDirectoryNoAccess
    /// The runtime went quiet for longer than its `idleTimeout` and the queue
    /// stopped waiting. Distinct from cancellation, which is the user's doing. A
    /// remote service may still finish, and bill, after this.
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
    /// An `Error` because it ends the request, but not one the user should see as
    /// a failure: the call succeeded and the service answered. The queue reports
    /// it through `.ready(message)` rather than the red `.error` banner.
    case refused(String)
}
