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

        Text("Number of Images")
            .sidebarLabelFormat()
        MochiSlider(
            value: $controller.numberOfImages, bounds: 1...100, step: 1,
            strictUpperBound: false)
    }
}

#Preview {
    NumberOfImagesView()
        .environment(GenerationController(configStore: ConfigStore()))
}
