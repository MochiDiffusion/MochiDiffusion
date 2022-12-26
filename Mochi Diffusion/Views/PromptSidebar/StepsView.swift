//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI
import Sliders

struct StepsView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        Text("Steps: \(store.steps)")
        ValueSlider(value: $store.steps, in: 2 ... 200, step: 1)
            .valueSliderStyle(
                HorizontalValueSliderStyle(
                    track:
                        HorizontalTrack(view: Color.accentColor)
                        .frame(height: 12)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(6),
                    thumbSize: CGSize(width: 12, height: 12),
                    options: .interactiveTrack
                )
            )
            .frame(height: 12)
    }
}

struct StepsView_Previews: PreviewProvider {
    static var previews: some View {
        StepsView()
    }
}
