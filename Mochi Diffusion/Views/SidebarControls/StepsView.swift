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
        CompactSlider(value: $genStore.steps, in: 2...40, step: 1) {
            Text(verbatim: "\(genStore.steps.formatted(.number.precision(.fractionLength(0))))")
            Spacer()
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
