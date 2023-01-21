//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct GuidanceScaleView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        Text("Guidance Scale:")
        CompactSlider(value: $genStore.guidanceScale, in: 1...20, step: 0.5) {
            Text(verbatim: "\(genStore.guidanceScale.formatted(.number.precision(.fractionLength(1))))")
            Spacer()
        }
        .compactSliderStyle(.mochi)
    }
}

struct GuidanceScaleView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        GuidanceScaleView()
            .environmentObject(genStore)
    }
}
