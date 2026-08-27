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
    case modelDirectoryNoAccess
    case modelSubDirectoriesNoAccess
    case noModelsFound
    case pipelineNotAvailable
    case requestedModelNotFound
}
