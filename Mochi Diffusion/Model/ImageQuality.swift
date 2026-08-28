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
