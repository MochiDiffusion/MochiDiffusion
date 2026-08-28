//
//  InputImage.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// One image handed to a generation as input.
///
/// What an engine *does* with it varies, and the difference is real rather than
/// cosmetic. Core ML Stable Diffusion treats a single image as a denoising start
/// and applies `strength` to it; Iris and the hosted engines treat images as
/// references attended to during generation, with no strength. Both are one list
/// in the sidebar, and each engine decides how to use and record what it is given.
///
/// `id` is stable per entry rather than derived from the image, so a list can hold
/// the same picture twice and reordering does not confuse SwiftUI. `CGImage` is not
/// `Equatable`, so equality is identity plus name — enough for the UI, and not a
/// claim about pixels.
nonisolated struct InputImage: Sendable, Identifiable {
    let id: UUID
    var image: CGImage
    /// The filename this came from, when it came from one. Recorded in metadata so
    /// an image can say what it was made from.
    var name: String?

    init(id: UUID = UUID(), image: CGImage, name: String? = nil) {
        self.id = id
        self.image = image
        self.name = name?.normalizedFilename
    }
}

nonisolated extension InputImage: Equatable {
    static func == (lhs: InputImage, rhs: InputImage) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

nonisolated extension [InputImage] {
    /// The names present, in order, skipping entries that never had one.
    ///
    /// Metadata records only the images it can name. An image pasted or dragged
    /// from another app has no filename, and inventing one would put a lie in the
    /// image rather than leaving a gap.
    var names: [String] {
        compactMap(\.name)
    }
}

nonisolated extension InputImagesConstraint {
    /// One image, ready to send: scaled, encoded, and paired with the name to
    /// record for it.
    struct Prepared: Sendable {
        var data: [Data]
        /// The names of those images in `data` that had one.
        ///
        /// Not positionally aligned with `data`, and deliberately: an image dragged
        /// in from another app has no filename, and the metadata contract is a list
        /// of the files a generation used, not a slot per image. So this can be
        /// shorter than `data` — never longer, and never naming an image that was
        /// dropped.
        var names: [String]
    }

    /// Truncates to what the model accepts, scales each image to `size`, and
    /// PNG-encodes it.
    ///
    /// Data and names are produced in one pass so they cannot disagree. Doing them
    /// separately is how metadata comes to claim a starting image that scaling
    /// silently failed to produce: the name came from the draft, the pixels did not
    /// arrive, and nothing noticed. An entry that fails to scale or encode is
    /// dropped from both.
    ///
    /// Every engine goes through here, so "what the model accepts" is enforced once
    /// rather than per engine.
    func prepared(_ requested: [InputImage], scaledTo size: CGSize) -> Prepared {
        var data: [Data] = []
        var names: [String] = []
        for input in resolved(requested) {
            guard
                let scaled = input.image.scaledAndCroppedTo(size: size),
                let encoded = scaled.pngData()
            else { continue }
            data.append(encoded)
            if let name = input.name {
                names.append(name)
            }
        }
        return Prepared(data: data, names: names)
    }
}
