//
//  ControlNetLink.swift
//  Mochi Diffusion
//

import Foundation

/// Keeps `<model>/controlnet` pointing at the configured ControlNet folder.
///
/// `StableDiffusionPipeline(resourcesAt:controlNet:)` resolves bundles relative to
/// the model directory, so a model generating with ControlNet needs them reachable
/// from inside its own folder. Mochi keeps one shared folder and links it in.
///
/// Called by the runtime for the model it is about to load, so nothing writes to
/// the user's models folder during discovery.
nonisolated enum ControlNetLink {
    private static let componentName = "controlnet"

    /// Points `<modelURL>/controlnet` at `configured` if it does not already, and
    /// returns the location ControlNet bundles will be loaded from.
    ///
    /// The returned value belongs in the pipeline cache key: without it, two
    /// folders holding same-named bundles are indistinguishable and a pipeline
    /// loaded from the previous folder would be reused for the life of the process.
    ///
    /// **A real directory is never replaced.** `ml-stable-diffusion` loads from
    /// `<model>/controlnet` whether or not it is a link, so a user may keep their
    /// own bundles there; an existing directory is treated as a deliberate
    /// override and its path returned. Only a confirmed symlink is ever removed.
    @discardableResult
    static func resolve(configured: URL, in modelURL: URL) -> String {
        let link = modelURL.appending(component: componentName)
        let linkPath = link.path(percentEncoded: false)
        let destination = configured.path(percentEncoded: false)
        let fileManager = FileManager.default

        // `attributesOfItem` reports on the link itself; `fileExists` follows it,
        // so a symlink to a missing folder would read as absent and one to a real
        // folder would be indistinguishable from a directory.
        let existingType =
            (try? fileManager.attributesOfItem(atPath: linkPath))?[.type] as? FileAttributeType

        switch existingType {
        case .none:
            try? fileManager.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: destination
            )
        case .typeSymbolicLink:
            let current = try? fileManager.destinationOfSymbolicLink(atPath: linkPath)
            guard current != destination else { return destination }
            try? fileManager.removeItem(at: link)
            try? fileManager.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: destination
            )
        default:
            // The user's own directory, or something that is not a directory at
            // all. Either way, not ours to delete.
            return linkPath
        }

        return destination
    }
}
