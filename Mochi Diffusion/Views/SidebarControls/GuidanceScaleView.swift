//
//  GuidanceScaleView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct GuidanceScaleView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var configStore = configStore

        let guidanceScale = controller.currentConstraints.guidanceScale

        // The row is shown for every model, including the guidance-distilled ones
        // that have no scale at all. Removing it moved everything below it, which
        // is a worse trade than one disabled field.
        Text("Guidance Scale")
            .sidebarLabelFormat()
        if let bounds = guidanceScale.bounds {
            // The slider keeps its own 0.5 granularity: the constraint says
            // what the model accepts, which is any value in range.
            MochiSlider(
                value: $configStore.guidanceScale,
                bounds: bounds,
                step: 0.5
            )
        } else if let pinned = guidanceScale.resolved(configStore.guidanceScale) {
            PinnedValueField(
                text: pinned.formatted(.number.precision(.fractionLength(1)))
            )
        } else {
            UnsupportedValueField()
        }
    }
}

#Preview {
    GuidanceScaleView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
