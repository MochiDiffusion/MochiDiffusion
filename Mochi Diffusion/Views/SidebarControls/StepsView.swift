//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct StepsView: View {
    @Environment(ImageController.self) private var controller: ImageController

    var body: some View {
        @Bindable var controller = controller

        Text("Steps")
            .sidebarLabelFormat()
        MochiSlider(value: $controller.steps, bounds: 1...50, step: 1, strictUpperBound: false)
    }
}

#Preview {
    StepsView()
        .environment(ImageController.shared)
}
