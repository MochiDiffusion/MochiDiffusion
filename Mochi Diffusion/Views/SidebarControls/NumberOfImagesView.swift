//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumberOfImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        @Bindable var controller = controller

        let numberOfImages = controller.currentConstraints.numberOfImages
        if let bounds = numberOfImages.bounds {
            Text("Number of Images")
                .sidebarLabelFormat()
            MochiSlider(
                value: $controller.numberOfImages,
                bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                step: 1,
                strictUpperBound: false
            )
        }
    }
}

#Preview {
    NumberOfImagesView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
