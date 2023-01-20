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
        CompactSlider(value: $genStore.guidanceScale, in: 1...20, step: 0.5) {
            Label("Guidance Scale", systemImage: "scalemass")
            Spacer()
            Text("\(genStore.guidanceScale.formatted(.number.precision(.fractionLength(1))))")
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
