//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumberOfImagesView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Number of Images")
            .sidebarLabelFormat()
        MochiSlider(
            value: $controller.numberOfImages, bounds: 1...100, step: 1, strictUpperBound: false)
    }
}

#Preview {
    NumberOfImagesView()
        .environmentObject(ImageController.shared)
}
