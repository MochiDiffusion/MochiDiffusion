//
//  StartingImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import SwiftUI

struct StartingImageView: View {
    @EnvironmentObject private var controller: ImageController
    @State private var isInfoPopoverShown = false

    var body: some View {
        Text(
            "Starting Image",
            comment: "Label for setting the starting image (commonly known as image2image)"
        )
        .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(image: controller.startingImage, size: controller.currentModel?.inputSize)
            { image in
                if let image {
                    ImageController.shared.setStartingImage(image: image)
                } else {
                    await ImageController.shared.unsetStartingImage()
                }
            }
            .frame(width: 90, height: 90)

            Spacer()

            VStack(alignment: .trailing) {
                HStack {
                    Button {
                        Task { await ImageController.shared.selectStartingImage() }
                    } label: {
                        Image(systemName: "photo")
                    }

                    Button {
                        Task { await ImageController.shared.unsetStartingImage() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }

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
        MochiSlider(value: $controller.strength, bounds: 0.0...1.0, step: 0.05)
    }
}

#Preview {
    StartingImageView()
        .environmentObject(ImageController.shared)
}
