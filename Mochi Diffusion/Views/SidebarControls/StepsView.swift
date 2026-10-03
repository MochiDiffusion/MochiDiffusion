//
//  StepsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct StepsView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var configStore = configStore

        let steps = controller.currentConstraints.steps

        Text("Steps")
            .sidebarLabelFormat()
        if let bounds = steps.bounds {
            MochiSlider(
                value: $configStore.steps,
                bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                step: 1,
                strictUpperBound: !steps.allowsValuesAboveBounds
            )
        } else if let pinned = steps.resolved(Int(configStore.steps)) {
            // Disabled rather than hidden, so a pinned value is visible
            PinnedValueField(text: String(pinned))
        }
    }
}

/// A read-only field for a value the model fixes.
struct PinnedValueField: View {
    let text: String

    var body: some View {
        TextField("", text: .constant(text))
            .frame(width: 60)
            .disabled(true)
            .opacity(0.6)
    }
}
