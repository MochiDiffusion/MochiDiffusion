//
//  StartingImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import SwiftUI

/// The image a generation denoises from — img2img.
///
/// Distinct from `InputImagesView`, and shown by its own constraint. There is
/// exactly one of these, it is scaled to the output size because that is what will
/// happen to it, and `strength` says how much of it survives. None of that is true
/// of a reference image.
///
/// The well passes the resolved output size, so the preview crops the way the
/// request will crop. `InputImagesView` passes `nil` for the same reason inverted:
/// a reference keeps its own resolution.
struct StartingImageView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @State private var isInfoPopoverShown = false

    private let wellSize: CGFloat = 90

    private var constraint: StartingImageConstraint {
        controller.currentConstraints.startingImage
    }

    /// The size the model will produce, which is the size the image will be cropped
    /// to.
    private var targetSize: CGSize {
        controller.currentConstraints.size.resolved(
            CGSize(width: configStore.width, height: configStore.height)
        )
    }

    var body: some View {
        Text(
            "Starting Image",
            comment: "Label for setting the starting image (commonly known as image2image)"
        )
        .sidebarLabelFormat()

        // Strength sits beside the well rather than beneath it. The row is already
        // as tall as the well, so the section keeps one height whether or not the
        // model has a strength, and the controls below it hold their positions when
        // the model changes. It also matches `InputImageRow`, which puts its
        // per-image controls in the same place.
        HStack(alignment: .top, spacing: 8) {
            ImageWellView(
                image: controller.startingImage?.edited,
                size: targetSize,
                selectImage: controller.selectImage,
                removeImage: controller.unsetStartingImage,
                removeHelp: String(
                    localized: "Remove starting image",
                    comment: "Tooltip for the button clearing the starting image"
                )
            ) { dropped in
                await controller.setStartingImage(
                    image: dropped.image,
                    filename: dropped.filename
                )
            }
            .frame(width: wellSize, height: wellSize)

            strengthControl
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var strengthControl: some View {
        @Bindable var configStore = configStore

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(
                    "Strength",
                    comment: "Label for starting image strength slider control"
                )
                .sidebarLabelFormat()

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

                Spacer()
            }

            // Bounds from the constraint rather than a literal 0...1, so a model that
            // accepts a narrower range gets a slider that matches it. A model with no
            // strength at all falls through to the placeholder rather than dropping the
            // row, so the section does not change shape.
            if let bounds = constraint.strength.bounds {
                MochiSlider(value: $configStore.strength, bounds: bounds, step: 0.05)
            } else if let pinned = constraint.strength.resolved(configStore.strength) {
                PinnedValueField(text: pinned.formatted(.number.precision(.fractionLength(2))))
            } else {
                UnsupportedValueField()
            }
        }
    }
}
