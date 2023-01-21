//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct StepsView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        Text("Steps:")
        CompactSlider(value: $genStore.steps, in: 2...100, step: 1) {
            Image(systemName: "square.3.layers.3d.down.backward")
            Spacer()
            Text(verbatim: "\(genStore.steps.formatted(.number.precision(.fractionLength(0))))")
        }
        .compactSliderStyle(.mochi)
    }
}

struct StepsView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        StepsView()
            .environmentObject(genStore)
    }
}
