//
//  StartingImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import SwiftUI

struct StartingImageView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @State private var isInfoPopoverShown = false

    var body: some View {
        @Bindable var configStore = configStore

        Text(
            "Starting Image",
            comment: "Label for setting the starting image (commonly known as image2image)"
        )
        .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(
                image: controller.startingImage,
                size: (controller.currentModel as? SDModel)?.inputSize
                    ?? CGSize(width: configStore.width, height: configStore.height),
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    controller.setStartingImage(image: image)
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

                    Button {
                        Task { await controller.unsetStartingImage() }
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
        MochiSlider(value: $configStore.strength, bounds: 0.0...1.0, step: 0.05)
    }
}

#Preview {
    StartingImageView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
