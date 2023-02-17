//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct GuidanceScaleView: View {
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Guidance Scale:")
        CompactSlider(value: $controller.guidanceScale, in: 1...20, step: 0.5) {
            Text(verbatim: "\(controller.guidanceScale.formatted(.number.precision(.fractionLength(1))))")
            Spacer()
        }
        .compactSliderStyle(.mochi)
    }
}

struct GuidanceScaleView_Previews: PreviewProvider {
    static var previews: some View {
        GuidanceScaleView()
            .environmentObject(ImageController.shared)
    }
}
