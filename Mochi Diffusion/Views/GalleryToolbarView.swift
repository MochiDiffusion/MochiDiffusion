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
        if case .loading = generator.state {
            Button {
                self.isStatusPopoverShown.toggle()
            } label: {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 16)
            }
            .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loading Model...")
                    Text(
                        "This may take up to 2 minutes if a model is used for the first time",
                        comment: "Help text for the loading model message"
                    )
                    .foregroundColor(.secondary)
                }
                .padding()
            }
        }

        if case let .running(progress) = generator.state, let progress = progress, progress.stepCount > 0 {
            let step = Int(progress.step) + 1
            let stepValue = Double(step) / Double(progress.stepCount)
            let progressValue = Double(generator.queueProgress.index + 1) / Double(generator.queueProgress.total)

            Button {
                self.isStatusPopoverShown.toggle()
            } label: {
                CircularProgressView(progress: stepValue)
                    .frame(width: 16, height: 16)
            }
            .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
                let stepLabel = String(
                    localized: "Step \(step) of \(progress.stepCount) - About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
                    comment: "Text displaying the current step progress and count"
                )
                let imageCountLabel = String(
                    localized: "Image \(generator.queueProgress.index + 1) of \(generator.queueProgress.total)",
                    comment: "Text displaying the image generation progress and count"
                )
                VStack(spacing: 12) {
                    ProgressView(stepLabel, value: stepValue, total: 1)
                    ProgressView(imageCountLabel, value: progressValue, total: 1)
                }
                .padding()
                .frame(width: 300)
            }
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
