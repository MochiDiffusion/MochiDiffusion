//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct GuidanceScaleView: View {
    @Environment(ImageController.self) private var controller: ImageController

    var body: some View {
        @Bindable var controller = controller

        Text("Guidance Scale")
            .sidebarLabelFormat()
        MochiSlider(value: $controller.guidanceScale, bounds: 1...20, step: 0.5)
    }
}

#Preview {
    GuidanceScaleView()
        .environment(ImageController.shared)
}
