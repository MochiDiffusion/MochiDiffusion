//
//  QuickLookState.swift
//  Mochi Diffusion
//

import SwiftUI

@MainActor
@Observable
final class QuickLookState {
    var url: URL?
    private var currentImageID: SDImage.ID?

    func toggle(image: SDImage?) {
        guard let image else {
            close()
            return
        }

        if currentImageID == image.id, url != nil {
            close()
            return
        }

        updateURL(for: image)
    }

    func updateSelection(_ image: SDImage?) {
        guard self.url != nil, let image else {
            close()
            return
        }

        updateURL(for: image)
    }

    func close() {
        currentImageID = nil
        url = nil
    }

    /// Points Quick Look at the file itself whenever there is one.
    ///
    /// A gallery image on disk needs no decoding, no re-encoding and no temporary
    /// copy. Only an image with no path, in practice a generation result not yet
    /// saved, is encoded to a temporary file.
    private func updateURL(for image: SDImage) {
        currentImageID = image.id

        if !image.path.isEmpty {
            url = URL(fileURLWithPath: image.path, isDirectory: false)
            return
        }

        guard
            let url = try? image.image?
                .asTransferableImage().image
                .temporaryFileURL()
        else {
            close()
            return
        }
        self.url = url
    }
}
