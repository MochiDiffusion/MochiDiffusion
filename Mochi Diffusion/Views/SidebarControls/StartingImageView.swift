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

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text("Starting Image")
                    .sidebarLabelFormat()
                ImageView(image: $controller.startingImage)
                    .frame(height: 80)
            }

            Spacer()

            VStack(alignment: .trailing) {
                Text("Strength")
                    .sidebarLabelFormat()
                Slider(value: $controller.strength, in: 0...1, step: 0.1)
                    .controlSize(.mini)
                    .frame(width: 85)

                Button {
                    Task { await ImageController.shared.selectStartingImage() }
                } label: {
                    Text("Select")
                }

                Button {
                    Task { await ImageController.shared.unsetStartingImage() }
                } label: {
                    Text("Clear")
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
