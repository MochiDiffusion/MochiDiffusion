//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct GuidanceScaleView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Guidance Scale")
            .sidebarLabelFormat()
        MochiSlider(value: $controller.guidanceScale, bounds: 1...20, step: 0.5)
    }
}

#Preview {
    GuidanceScaleView()
        .environmentObject(ImageController.shared)
}
