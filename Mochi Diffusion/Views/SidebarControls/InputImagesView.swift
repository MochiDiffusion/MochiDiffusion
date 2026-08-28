//
//  InputImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import SwiftUI

/// The images handed to a generation as input.
///
/// One control for what used to be two ideas. A model that takes exactly one image
/// and applies strength to it is doing img2img and says "Starting Image"; a model
/// that attends to several references says "Input Images". Which it is comes from
/// the model's `InputImagesConstraint`, not from which engine is selected.
struct InputImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @State private var isInfoPopoverShown = false

    var body: some View {
        Text(sectionLabel)
            .sidebarLabelFormat()

        if constraint.acceptsMultiple {
            multipleImages
        } else {
            singleImage
        }

        if constraint.strength.isSupported {
            strengthControl
        }
    }

    // MARK: - One image

    /// Preserved as it was: a single well with a pick and a clear button. A model
    /// that takes one image should not grow a list UI for it.
    @ViewBuilder private var singleImage: some View {
        HStack(alignment: .top) {
            ImageWellView(
                image: controller.inputImages.first?.image,
                size: targetSize,
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    await controller.setStartingImage(image: image)
                } else {
                    await controller.unsetStartingImage()
                }
            }
            .frame(width: 90, height: 90)

            Spacer()

            VStack(alignment: .trailing) {
                HStack {
                    Button {
                        Task { await controller.selectStartingImage() }
                    } label: {
                        Image(systemName: "photo")
                    }
                    .help("Choose an image")

                    Button {
                        Task { await controller.unsetStartingImage() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .help("Remove the image")
                }
            }
        }
    }

    // MARK: - Several images

    @ViewBuilder private var multipleImages: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(controller.inputImages.enumerated()), id: \.element.id) { index, input in
                inputImageRow(input, index: index)
            }

            HStack {
                Button {
                    Task { await controller.selectAdditionalInputImage() }
                } label: {
                    Label {
                        Text("Add Image", comment: "Button to add another input image")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .disabled(controller.inputImages.count >= constraint.maxCount)

                Spacer()

                Text(verbatim: "\(controller.inputImages.count)/\(constraint.maxCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func inputImageRow(_ input: InputImage, index: Int) -> some View {
        HStack(alignment: .top) {
            ImageWellView(
                image: input.image,
                size: targetSize,
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    await controller.replaceInputImage(id: input.id, with: image)
                } else {
                    await controller.removeInputImage(id: input.id)
                }
            }
            .frame(width: 60, height: 60)
            // The controller keeps every image the user chose even when the
            // selected model takes fewer, so a switch to a narrower model does not
            // silently discard them. Saying which ones will not be used is better
            // than either hiding them or pretending they count.
            .opacity(index < constraint.maxCount ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 2) {
                if let name = input.name {
                    Text(verbatim: name)
                        .font(.caption)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("Untitled", comment: "An input image with no filename")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if index >= constraint.maxCount {
                    Text(
                        "Not used by this model",
                        comment: "An input image beyond what the selected model accepts"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                controller.removeInputImage(id: input.id)
            } label: {
                Image(systemName: "xmark")
            }
            .help("Remove this image")
        }
    }

    // MARK: - Strength

    @ViewBuilder private var strengthControl: some View {
        @Bindable var configStore = configStore

        HStack {
            Text(
                "Strength",
                comment: "Label for starting image strength slider control"
            )
            .sidebarLabelFormat()

            Spacer()

            Button {
                self.isInfoPopoverShown.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(Color.secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .popover(isPresented: self.$isInfoPopoverShown, arrowEdge: .top) {
                Text(
                    """
                    Strength controls how closely the generated image resembles the starting image.
                    Use lower values to generate images that look similar to the starting image.
                    Use higher values to allow more creative freedom.

                    The size of the starting image must match the output image size of the current model.
                    """
                )
                .padding()
            }
        }
        if let bounds = constraint.strength.bounds {
            MochiSlider(value: $configStore.strength, bounds: bounds, step: 0.05)
        } else if let pinned = constraint.strength.resolved(configStore.strength) {
            PinnedValueField(text: pinned.formatted(.number.precision(.fractionLength(2))))
        } else {
            UnsupportedValueField()
        }
    }

    // MARK: - Reading the constraint

    private var constraint: InputImagesConstraint {
        controller.currentConstraints.inputImages
    }

    /// A model with a fixed input size needs its images at that size, so the well
    /// crops its preview the way the request will.
    private var targetSize: CGSize {
        controller.currentConstraints.size.resolved(
            CGSize(width: configStore.width, height: configStore.height)
        )
    }

    /// "Starting Image" when the model denoises from one, "Input Images" when it
    /// attends to several. Strength is what distinguishes them: it only means
    /// anything for a denoising origin.
    private var sectionLabel: String {
        if constraint.acceptsMultiple {
            return String(
                localized: "Input Images",
                comment: "Label for the input images a model attends to"
            )
        }
        return String(
            localized: "Starting Image",
            comment: "Label for setting the starting image (commonly known as image2image)"
        )
    }
}

#Preview {
    InputImagesView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
