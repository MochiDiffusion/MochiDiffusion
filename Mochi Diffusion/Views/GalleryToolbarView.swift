//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @EnvironmentObject var genStore: GeneratorStore
    @State private var isStatusPopoverShown = false

    var body: some View {
        if case .loading = genStore.status {
            Button {
                self.isStatusPopoverShown.toggle()
            } label: {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.5)
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

        if case let .running(progress) = genStore.status, let progress = progress, progress.stepCount > 0 {
            let step = Int(progress.step) + 1
            let stepValue = Double(step) / Double(progress.stepCount)
            let progressValue = Double(genStore.generationProgress.index + 1) / Double(genStore.generationProgress.total)

            Button {
                self.isStatusPopoverShown.toggle()
            } label: {
                CircularProgressView(progress: stepValue)
                    .frame(width: 16, height: 16)
            }
            .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
                let stepLabel = String(
                    localized: "Step \(step) of \(progress.stepCount)",
                    comment: "Text displaying the current step progress and count"
                )
                let imageCountLabel = String(
                    localized: "Image \(genStore.generationProgress.index + 1) of \(genStore.generationProgress.total)",
                    comment: "Text displaying the image generation progress and count"
                )
                VStack(alignment: .center, spacing: 12) {
                    ProgressView(stepLabel, value: stepValue, total: 1)
                    ProgressView(imageCountLabel, value: progressValue, total: 1)
                }
                .padding()
                .frame(width: 300)
            }
        }

        if let sdi = genStore.getSelectedImage, let img = sdi.image {
            let imageView = Image(img, scale: 1, label: Text(verbatim: sdi.prompt))

            Button(action: genStore.removeCurrentImage) {
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
                genStore.upscaleCurrentImage()
            } label: {
                Label {
                    Text("Convert to High Resolution")
                } icon: {
                    Image(systemName: "wand.and.stars")
                }
                .help("Convert to High Resolution")
            }

            Spacer()

            Button(action: sdi.save) {
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
}

struct GalleryToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        GalleryToolbarView()
    }
}
