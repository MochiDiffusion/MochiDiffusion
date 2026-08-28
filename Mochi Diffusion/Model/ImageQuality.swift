//
//  ImageQuality.swift
//  Mochi Diffusion
//

import Foundation

/// How much effort a model should spend on an image.
///
/// A hosted service's vocabulary: the two local engines have no equivalent and
/// declare it `.unsupported`. Kept as a closed enum with stable raw values
/// because those raw values reach both the wire and the image metadata — §6
/// learned the cost of a display string doubling as a persisted identifier the
/// expensive way with `Scheduler`, and `displayName` is separate here for that
/// reason.
nonisolated enum ImageQuality: String, CaseIterable, Sendable, Identifiable {
    /// Let the service pick. A real value rather than an absence: it is what the
    /// API defaults to, and it is a reasonable thing for a user to choose.
    case auto
    case low
    case medium
    case high

    var id: String { rawValue }

    /// Reads a quality recorded in image metadata, or `nil` when it is not one
    /// this build knows.
    ///
    /// `nil` deliberately means "leave the current selection alone" to whoever
    /// asked. An image written by a later build naming a quality we do not have
    /// must not be quietly read as `auto`: that would put a value in the sidebar
    /// the image never used, which is the same class of defect as a scheduler
    /// importing as DPM-Solver++ because its name was unrecognised.
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
