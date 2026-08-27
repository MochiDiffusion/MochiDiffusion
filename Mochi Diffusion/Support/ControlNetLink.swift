//
//  ControlNetLink.swift
//  Mochi Diffusion
//

import Foundation

/// Keeps `<model>/controlnet` pointing at the configured ControlNet folder.
///
/// Apple's `StableDiffusionPipeline(resourcesAt:controlNet:)` resolves bundles
/// relative to the model directory, so a model that generates with ControlNet
/// needs them reachable from inside its own folder. Mochi keeps one shared folder
/// and links it in.
///
/// Used to be done during discovery, for every capable model, on every
/// folder-change event — a write on a read path. Now the runtime does it for the
/// one model it is about to load.
nonisolated enum ControlNetLink {
    private static let componentName = "controlnet"

    /// Points `<modelURL>/controlnet` at `configured` if it does not already, and
    /// returns the location ControlNet bundles will actually be loaded from.
    ///
    /// The returned value belongs in the pipeline cache key. Without it, changing
    /// the configured folder produced an identical key, so a pipeline loaded from
    /// the old folder was reused for as long as the app ran.
    ///
    /// **A real directory is never replaced.** `ml-stable-diffusion` loads from
    /// `<model>/controlnet` whether or not that is a link, so someone who does not
    /// use Mochi's shared folder may keep their own bundles there. Replacing a
    /// directory means deleting it and everything in it, so an existing directory
    /// is treated as a deliberate override and left alone — its path is returned,
    /// which is where the pipeline will read from.
    ///
    /// Only a symlink is ever removed, and only after being confirmed to be one.
    @discardableResult
    static func resolve(configured: URL, in modelURL: URL) -> String {
        let link = modelURL.appending(component: componentName)
        let linkPath = link.path(percentEncoded: false)
        let destination = configured.path(percentEncoded: false)
        let fileManager = FileManager.default

        // Deliberately `attributesOfItem`, which reports on the link itself rather
        // than following it. `fileExists` follows, so a symlink to a missing
        // folder reads as absent and a symlink to a real one is
        // indistinguishable from a directory.
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
