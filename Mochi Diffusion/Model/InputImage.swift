//
//  InputImage.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// One image handed to a generation as input, either as starting or reference image.
///
/// `id` is stable per entry rather than derived from the image, so a list can hold
/// the same picture twice and reordering does not confuse SwiftUI.
nonisolated struct InputImage: Sendable, Identifiable {
    let id: UUID
    var image: CGImage
    /// The filename, when available
    var name: String?
    /// The crop, as fractions of each edge. `.identity` is the whole image.
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

nonisolated extension InputImagesConstraint {
    /// One image, ready to send: scaled, encoded, and paired with the name to
    /// record for it.
    struct Prepared: Sendable {
        var data: [Data]
        /// Positionally aligned with `data`, so an unnamed image cannot shift every
        /// later filename onto the wrong set of pixels. Metadata writers compact
        /// this list because the persisted format records names rather than slots.
        var names: [String?]
    }

    /// Truncates to what the model accepts, applies each image's crop, hands it to
    /// `resize`, and PNG-encodes the result.
    ///
    /// `resize` is the engine's own: Core ML scales to its fixed input size, Iris
    /// fits each reference to the size its attention budget leaves for it, and
    /// returning `nil` sends the cropped image at its own size. Cropping and
    /// encoding are shared because they are the same everywhere.
    ///
    /// Data and names are produced in one pass so metadata cannot name an image
    /// whose pixels were not produced. An entry that fails to encode is dropped
    /// from both.
    ///
    /// Every engine goes through here, so "what the model accepts" is enforced once
    /// rather than per engine.
    func prepared(
        _ requested: [InputImage],
        resize: (CGImage, Int) -> CGImage?
    ) -> Prepared {
        var data: [Data] = []
        var names: [String?] = []
        for (index, input) in resolved(requested).enumerated() {
            let cropped = input.edited
            let sized = resize(cropped, index) ?? cropped
            // The redraw fallback matters for a dragged-in 16-bit or CMYK image,
            // which the PNG destination refuses outright.
            guard let encoded = sized.pngData() ?? sized.normalizedRGBA8Image()?.pngData()
            else { continue }
            data.append(encoded)
            names.append(input.name)
        }
        return Prepared(data: data, names: names)
    }

    /// The common case: one fixed size for every image.
    func prepared(_ requested: [InputImage], scaledTo size: CGSize) -> Prepared {
        prepared(requested) { image, _ in image.scaledAndCroppedTo(size: size) }
    }
}

nonisolated extension StartingImageConstraint {
    /// Crops, scales to `size` and encodes the starting image, or produces nothing
    /// when the model does not denoise from one.
    ///
    /// Always scaled to the output size, unlike a reference: a denoising origin has
    /// to match the latent it seeds.
    func prepared(_ requested: InputImage?, scaledTo size: CGSize)
        -> InputImagesConstraint.Prepared
    {
        guard let image = resolved(requested) else {
            return InputImagesConstraint.Prepared(data: [], names: [])
        }
        // Reuses the reference path's crop/encode/name pairing so a starting image
        // cannot record a name for pixels that failed to encode either.
        return InputImagesConstraint.supported(maxCount: 1)
            .prepared([image]) { cropped, _ in cropped.scaledAndCroppedTo(size: size) }
    }
}
