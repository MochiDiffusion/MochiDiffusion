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

    private func updateURL(for image: SDImage) {
        guard
            let url = try? image.image?
                .asTransferableImage().image
                .temporaryFileURL()
        else {
            close()
            return
        }

        currentImageID = image.id
        self.url = url
    }
}
