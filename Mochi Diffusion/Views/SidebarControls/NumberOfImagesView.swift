//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct NumberOfImagesView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Number of Images:")
        CompactSlider(value: $controller.numberOfImages, in: 1...100, step: 1) {
            Text(verbatim: "\(controller.numberOfImages.formatted(.number.precision(.fractionLength(0))))")
            Spacer()
        }
        .compactSliderStyle(.mochi)
    }
}

struct NumberOfImagesView_Previews: PreviewProvider {
    static var previews: some View {
        NumberOfImagesView()
            .environmentObject(ImageController.shared)
    }
}
