//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @Binding var isShowingInspector: Bool
    @EnvironmentObject private var generator: ImageGenerator
    @EnvironmentObject private var store: ImageStore
    @State private var isStatusPopoverShown = false

    var body: some View {
        Button {
            self.isStatusPopoverShown.toggle()
        } label: {
            if case let .running(progress) = generator.state, let progress = progress, progress.stepCount > 0 {
                let step = Int(progress.step) + 1
                let stepValue = Double(step) / Double(progress.stepCount)
                CircularProgressView(progress: stepValue)
                    .frame(width: 16, height: 16)
            } else if case .loading = generator.state {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                // to prevent UI flicker when transitioning from running to ready to loading
                Color.clear
                    .frame(width: 16, height: 16)
            }
        }
        .disabled(generator.state == .ready(nil))
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
                Task { await ImageController.shared.removeCurrentImage() }
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
            Button {
                Task { await ImageController.shared.upscaleCurrentImage() }
            } label: {
                Label {
                    Text("Convert to High Resolution")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .help("Convert to High Resolution")
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
            withAnimation {
                isShowingInspector.toggle()
            }
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

        Button {
            // noop
        } label: {
            Label {
                Text("Convert to High Resolution")
            } icon: {
                Image(systemName: "wand.and.stars")
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

struct GalleryToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryToolbarView(isShowingInspector: .constant(true))
            .environmentObject(ImageGenerator.shared)
            .environmentObject(ImageStore.shared)
    }
}
