//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI
import Sliders

struct GuidanceScaleView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        Text("Guidance Scale: \(store.guidanceScale, specifier: "%.1f")",
             tableName: "Prompt",
             comment: "Label for Guidance Scale slider with value")
        ValueSlider(value: $store.guidanceScale, in: 1 ... 20, step: 0.5)
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

struct GuidanceScaleView_Previews: PreviewProvider {
    static var previews: some View {
        GuidanceScaleView()
    }
}
