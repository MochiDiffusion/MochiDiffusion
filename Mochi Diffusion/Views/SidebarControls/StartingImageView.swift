//
//  StartingImageView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/27/23.
//

import CompactSlider
import SwiftUI

struct ImageView: View {
    @Binding var image: CGImage?

    var body: some View {
        if let image = image {
            Image(image, scale: 1, label: Text(verbatim: ""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        } else {
            Image(systemName: "photo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(Color(nsColor: .separatorColor))
                .padding(30)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }
}

struct StartingImageView: View {
    @EnvironmentObject private var controller: ImageController
    @State private var isInfoPopoverShown = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(
                    "Starting Image",
                    comment: "Label for setting the starting image (commonly known as image2image)"
                )
                .sidebarLabelFormat()

                ImageView(image: $controller.startingImage)
                    .frame(height: 90)
            }

            Spacer()

            VStack(alignment: .trailing) {
                Text(
                    "Strength",
                    comment: "Label for starting image strength slider control"
                )
                .sidebarLabelFormat()

                Slider(value: $controller.strength, in: 0.685...1, step: 0.035)
                    .controlSize(.mini)
                    .frame(width: 88)

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
                    Strength controls how closely the generated image resembles the starting image vs following the text prompt.
                    Use lower values to generate images that look more like the starting image.
                    Use higher values to generate images that more closely follow the text prompt.

                    The size of the starting image must match the output image size of the current model.
                    """
                    )
                    .padding()
                }
            }
        }
    }
}

struct StartingImageView_Previews: PreviewProvider {
    static var previews: some View {
        StartingImageView()
            .environmentObject(ImageController.shared)
    }
}
