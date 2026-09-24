//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @Environment(GenerationState.self) private var generationState: GenerationState
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(GalleryController.self) private var galleryController: GalleryController
    @Binding var isShowingInspector: Bool
    @State private var isStatusPopoverShown = false

    var body: some View {
        @Bindable var store = store

        ZStack {
            if case .running(let progress) = generationState.state, let progress = progress,
                progress.stepCount > 0
            {
                let step = progress.step + 1
                let stepValue = Double(step) / Double(progress.stepCount)

                Button {
                    self.isStatusPopoverShown.toggle()
                } label: {
                    CircularProgressView(progress: stepValue)
                        .frame(width: 16, height: 16)
                }
            } else if case .loading(_) = generationState.state {
                Button {
                    self.isStatusPopoverShown.toggle()
                } label: {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            } else if case .canceling(_) = generationState.state {
                Button {
                    self.isStatusPopoverShown.toggle()
                } label: {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }
        }
        .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
            JobQueueView()
                .frame(width: 420, height: 240)
        }

        Picker("Sort", selection: $store.sortType) {
            Text(
                "Oldest First",
                comment: "Picker option to sort images in the gallery from oldest to newest"
            ).tag(ImagesSortType.oldestFirst)

            Text(
                "Newest First",
                comment: "Picker option to sort images in the gallery from newest to oldest"
            )
            .tag(ImagesSortType.newestFirst)
        }

        // Gated on there being a selection, not on its pixels being in memory: a
        // gallery image loaded from disk has no decoded image.
        if let sdi = store.selected() {
            Button {
                Task { await galleryController.removeCurrentImage() }
            } label: {
                Label {
                    Text(
                        "Remove",
                        comment: "Toolbar button to remove the selected image"
                    )
                } icon: {
                    Image(systemName: "trash")
                }
                .help("Remove")
            }

            Spacer()

            Button {
                Task { await sdi.saveAs() }
            } label: {
                Label {
                    Text(
                        "Save As...",
                        comment: "Toolbar button to show the save image dialog"
                    )
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save As...")
            }
            shareLink(for: sdi)
        } else {
            disabledToolbarActionView
        }

        Button {
            isShowingInspector.toggle()
        } label: {
            Label {
                Text(
                    "Toggle Info Panel",
                    comment: "Toolbar button to hide or show the info panel"
                )
            } icon: {
                Image(systemName: "sidebar.right")
            }
        }

        FilterTextFieldView(filters: $store.filters)
            .frame(minWidth: 300)
            .frame(maxWidth: 500)
            .frame(height: 40)
    }

    /// Shares the file when there is one, and the pixels when there is not.
    ///
    /// The file is the better thing to share regardless — it carries the image's
    /// metadata, which an `Image` rendered from a `CGImage` does not — and it is the
    /// only option for a gallery image that was never decoded.
    @ViewBuilder private func shareLink(for sdi: SDImage) -> some View {
        if !sdi.path.isEmpty {
            ShareLink(item: URL(fileURLWithPath: sdi.path, isDirectory: false))
                .help("Share...")
        } else if let image = sdi.image {
            let imageView = Image(image, scale: 1, label: Text(verbatim: sdi.prompt))
            ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                .help("Share...")
        } else {
            Button {
                // noop
            } label: {
                Label {
                    Text("Share...", comment: "Toolbar button to show the system share sheet")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(true)
        }
    }

    @ViewBuilder private var disabledToolbarActionView: some View {
        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Remove",
                    comment: "Toolbar button to remove the selected image"
                )
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(true)

        Spacer()

        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Save As...",
                    comment: "Toolbar button to show the save image dialog"
                )
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .disabled(true)

        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Share...",
                    comment: "Toolbar button to show the system share sheet"
                )
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(true)
    }
}
