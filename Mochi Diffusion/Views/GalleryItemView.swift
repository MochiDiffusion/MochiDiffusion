//
//  GalleryItemView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryItemView: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.galleryThumbnailProvider) private var thumbnailProvider
    let sdi: SDImage
    @State private var thumbnail: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // `sdi.image` is the fallback rather than the source: it is set only
                // for a freshly generated image, whose pixels are already in hand.
                // Everything loaded from disk arrives here as a thumbnail.
                if let image = thumbnail ?? sdi.image {
                    Image(image, scale: 1, label: Text(verbatim: String(sdi.seed)))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(4)
                } else {
                    Color.clear
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }
                Text(finderTagColorNumberToString(self.sdi.finderTagColorNumber))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(8)
            }
            .task(id: requestID(for: geometry.size)) {
                await loadThumbnail(for: geometry.size)
            }
        }
    }

    /// Re-requests only when the image or the bucketed size changes, so a drag that
    /// resizes the window by a few points does not restart the load on every frame.
    private func requestID(for size: CGSize) -> String {
        "\(sdi.id.uuidString)#\(thumbnailPixelSize(for: size))"
    }

    /// The rendered size in *pixels*, rounded up into 32px buckets.
    ///
    /// Bucketing is what keeps the cache key stable while a window is being dragged:
    /// without it every point of resize is a distinct key and a fresh decode. The
    /// 1024 ceiling is because a gallery cell is never usefully larger than that, and
    /// the 64 floor keeps a very small cell from asking for something unrecognisable.
    private func thumbnailPixelSize(for size: CGSize) -> Int {
        let logicalMaxDimension = max(size.width, size.height)
        guard logicalMaxDimension > 0 else { return 0 }

        let scaledMaxDimension = Int((logicalMaxDimension * displayScale).rounded(.up))
        let roundedMaxDimension = ((scaledMaxDimension + 31) / 32) * 32
        return min(max(roundedMaxDimension, 64), 1_024)
    }

    private func loadThumbnail(for size: CGSize) async {
        // A generated image already has its pixels; nothing to read.
        guard sdi.image == nil else { return }
        let maxPixelSize = thumbnailPixelSize(for: size)
        guard maxPixelSize > 0, !sdi.path.isEmpty else { return }
        thumbnail = await thumbnailProvider.thumbnail(
            for: sdi.path,
            maxPixelSize: maxPixelSize
        )
    }
}
