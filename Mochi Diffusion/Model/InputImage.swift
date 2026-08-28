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
    /// The crop the user dragged out in the sidebar, as fractions of each edge.
    /// `.identity` is the whole image.
    var edit: IrisReferenceImageEdit

    init(
        id: UUID = UUID(),
        image: CGImage,
        name: String? = nil,
        edit: IrisReferenceImageEdit = .identity
    ) {
        self.id = id
        self.image = image
        self.name = name?.normalizedFilename
        self.edit = edit
    }

    /// The image with its crop applied, which is what every engine actually sends.
    var edited: CGImage {
        IrisReferenceImageProcessor.applyEdits(to: image, edit: edit) ?? image
    }

    /// The pixel size after cropping, for the sidebar's readout.
    var editedSize: CGSize {
        IrisReferenceImageProcessor.editedPixelSize(for: image, edit: edit)
    }
}

nonisolated extension InputImage: Equatable {
    static func == (lhs: InputImage, rhs: InputImage) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.edit == rhs.edit
    }
}

nonisolated extension Array {
    /// The element at `index`, or `nil` when it is out of bounds.
    ///
    /// Used where two lists are expected to line up — input images and the sizes
    /// predicted for them — and a mismatch should degrade rather than trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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

    /// Truncates to what the model accepts, applies each image's crop, hands it to
    /// `resize`, and PNG-encodes the result.
    ///
    /// `resize` is the engine's own: Core ML scales to its fixed input size, Iris
    /// fits each reference to the size its attention budget leaves for it, and
    /// returning `nil` sends the cropped image at its own size. Cropping and
    /// encoding are shared because they are the same everywhere.
    ///
    /// Data and names are produced in one pass so they cannot disagree. Doing them
    /// separately is how metadata comes to claim an image that resizing silently
    /// failed to produce: the name came from the draft, the pixels did not arrive,
    /// and nothing noticed. An entry that fails to encode is dropped from both.
    ///
    /// Every engine goes through here, so "what the model accepts" is enforced once
    /// rather than per engine.
    func prepared(
        _ requested: [InputImage],
        resize: (CGImage, Int) -> CGImage?
    ) -> Prepared {
        var data: [Data] = []
        var names: [String] = []
        for (index, input) in resolved(requested).enumerated() {
            let cropped = input.edited
            let sized = resize(cropped, index) ?? cropped
            // The redraw fallback matters for a dragged-in 16-bit or CMYK image,
            // which the PNG destination refuses outright.
            guard let encoded = sized.pngData() ?? sized.normalizedRGBA8Image()?.pngData()
            else { continue }
            data.append(encoded)
            if let name = input.name {
                names.append(name)
            }
        }
        return Prepared(data: data, names: names)
    }

    /// The common case: one fixed size for every image.
    func prepared(_ requested: [InputImage], scaledTo size: CGSize) -> Prepared {
        prepared(requested) { image, _ in image.scaledAndCroppedTo(size: size) }
    }
}
