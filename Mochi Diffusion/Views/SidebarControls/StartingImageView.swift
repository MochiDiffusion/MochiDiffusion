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
        VStack(alignment: .leading) {
            Text(
                "Image-to-image",
                comment: "Label for setting the starting image (commonly known as image2image)"
            )
            .sidebarLabelFormat()
            
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    ImageView(image: $controller.startingImage)
                        .frame(height: 90)
                }
                
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
            CompactSlider(value: $controller.strength, in: 0.0...1.0, step: 0.05) {
                Text(verbatim: "\(controller.strength.formatted(.number.precision(.fractionLength(2))))")
                Spacer()
            }
             .compactSliderStyle(.mochi)
        }
    }
}

struct StartingImageView_Previews: PreviewProvider {
    static var previews: some View {
        StartingImageView()
            .environmentObject(ImageController.shared)
    }
}
