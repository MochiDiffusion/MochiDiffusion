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
            // Disabled rather than hidden, so a pinned value is visible: a
            // distilled model always takes four steps.
            PinnedValueField(text: String(pinned))
        } else {
            UnsupportedValueField()
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

/// A placeholder for an option the model does not have at all.
///
/// Holds the row open so the controls below it keep their positions when the
/// selected model changes, and reads as "not applicable" rather than showing a
/// number the model would ignore.
struct UnsupportedValueField: View {
    var body: some View {
        PinnedValueField(text: "\u{2014}")
            // The field inside is disabled and so never sees the pointer. The
            // overlay is not, which is what makes the tooltip reachable.
            .overlay {
                Color.clear
                    .contentShape(Rectangle())
                    .help("Not used by this model")
            }
    }
}

#Preview {
    StepsView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
