//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct StepsView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Steps")
            .sidebarLabelFormat()
        CompactSlider(value: $controller.steps, in: 2...50, step: 1) {
            Text(verbatim: "\(controller.steps.formatted(.number.precision(.fractionLength(0))))")
            Spacer()
        }
        .compactSliderStyle(.mochi)
    }
}

struct StepsView_Previews: PreviewProvider {
    static var previews: some View {
        StepsView()
            .environmentObject(ImageController.shared)
    }
}
