//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct StepsView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Steps")
            .sidebarLabelFormat()
        MochiSlider(value: $controller.steps, bounds: 1...50, step: 1, strictUpperBound: false)
    }
}

#Preview {
    StepsView()
        .environmentObject(ImageController.shared)
}
