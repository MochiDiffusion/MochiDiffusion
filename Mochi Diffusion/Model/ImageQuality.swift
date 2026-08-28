//
//  ImageQuality.swift
//  Mochi Diffusion
//

import Foundation

/// How much effort a model should spend on an image.
///
/// A hosted service's vocabulary; the local engines declare it `.unsupported`.
/// The raw values reach both the wire and the image metadata, so they are stable
/// and `displayName` is kept separate from them.
nonisolated enum ImageQuality: String, CaseIterable, Sendable, Identifiable {
    /// Let the service pick. A real value rather than an absence — it is what
    /// the API defaults to.
    case auto
    case low
    case medium
    case high

    var id: String { rawValue }

    /// Reads a quality recorded in image metadata, or `nil` when it is not one
    /// this build knows.
    ///
    /// `nil` means "leave the current selection alone". An image from a later
    /// build naming a quality this one lacks must not read as `auto`, which would
    /// put a value in the sidebar the image never used.
    init?(_ recorded: String) {
        guard let quality = ImageQuality(rawValue: recorded) else { return nil }
        self = quality
    }

    var displayName: String {
        switch self {
        case .auto:
            return String(localized: "Auto", comment: "Image quality: let the service choose")
        case .low:
            return String(localized: "Low", comment: "Image quality")
        case .medium:
            return String(localized: "Medium", comment: "Image quality")
        case .high:
            return String(localized: "High", comment: "Image quality")
        }
    }
}
