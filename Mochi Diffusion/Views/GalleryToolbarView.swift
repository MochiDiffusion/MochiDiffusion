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
            } else if case .loading = generationState.state {
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

        if let sdi = store.selected(), let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text(verbatim: sdi.prompt))

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
            ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                .help("Share...")
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

    @ViewBuilder
    private var disabledToolbarActionView: some View {
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

#Preview {
    let focusController = FocusController()
    GalleryToolbarView(isShowingInspector: .constant(true))
        .environment(GenerationState.shared)
        .environment(ImageGallery.shared)
        .environment(ConfigStore())
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(
            GalleryController(
                configStore: ConfigStore(),
                focusController: focusController
            )
        )
}
