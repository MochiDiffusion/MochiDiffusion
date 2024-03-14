//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @Binding var isShowingInspector: Bool
    @Environment(ImageGenerator.self) private var generator: ImageGenerator
    @Environment(ImageStore.self) private var store: ImageStore
    @State private var isStatusPopoverShown = false

    var body: some View {
        @Bindable var store = store

        HStack {
            if shouldShowProgress(forState: generator.state) {
                progressBarView()
                Button {
                    Task { await generator.stopGenerate() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }

            ZStack {
                if case .running(let progress) = generator.state, let progress = progress,
                progress.stepCount > 0
            {
                    Button {
                        self.isStatusPopoverShown.toggle()
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .frame(width: 16, height: 16)
                    }
                } else if case .loading = generator.state {
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
        }
        .frame(width: 400)

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

    @ViewBuilder
    private func progressBarView() -> some View {
        VStack(spacing: 0) {
            if case let .running(progress) = generator.state, let progress = progress, progress.stepCount > 0 {
                let step = progress.step + 1
                let stepValue = Double(step) / Double(progress.stepCount)
                let progressText = String(
                    localized: "About \(formatTimeRemaining(generator.lastStepGenerationElapsedTime, stepsLeft: progress.stepCount - step))",
                    comment: "Text displaying the current time remaining"
                )

                ProgressView(value: stepValue)
                    .progressViewStyle(LinearProgressViewStyle())
                    .frame(height: 12)
                    .padding(.top, 4)
                    .padding([.leading, .trailing], 8)
                Text(progressText)
                    .font(.caption)
                    .padding(.bottom, 4)
                    .padding([.leading, .trailing], 8)
            } else if case .loading = generator.state {
                let progressLabel = String(
                    localized: "Loading the model...",
                    comment: "Text displayed when the model is being loaded"
                )
                Text(progressLabel)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .background(Color.gray.opacity(0.05))
        .cornerRadius(4)
    }

    func shouldShowProgress(forState state: ImageGenerator.State) -> Bool {
        switch state {
        case .loading, .running:
            return true
        default:
            return false
        }
    }
}

#Preview {
    GalleryToolbarView(isShowingInspector: .constant(true))
        .environment(ImageGenerator.shared)
        .environment(ImageStore.shared)
}
