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

        // Shown for every model, so the controls below keep their positions.
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
