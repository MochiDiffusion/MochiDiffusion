//
//  NumberOfImagesView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CompactSlider
import SwiftUI

struct NumberOfImagesView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        CompactSlider(value: $genStore.numberOfImages, in: 1...100, step: 1) {
            Label("Images", systemImage: "photo.stack")
            Spacer()
            Text(verbatim: "\(genStore.numberOfImages.formatted(.number.precision(.fractionLength(0))))")
        }
        .compactSliderStyle(.mochi)
    }
}

struct NumberOfImagesView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        NumberOfImagesView()
            .environmentObject(genStore)
    }
}
