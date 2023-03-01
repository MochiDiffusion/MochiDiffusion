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
                .padding(4)
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
                    .frame(height: 80)
            }

            Spacer()

            VStack(alignment: .trailing) {
                Text(
                    "Strength",
                    comment: "Label for image2image strength slider control"
                )
                .sidebarLabelFormat()

                Slider(value: $controller.strength, in: 0.1...1, step: 0.1)
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
                    Use the same model along with **Copy Options to Sidebar** to get similar images.
                    Note that the starting image size must match the size of the image that will be generated.
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
