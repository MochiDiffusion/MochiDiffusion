//
//  QualityView.swift
//  Mochi Diffusion
//

import SwiftUI

/// Picks how much effort a model should spend on an image.
///
/// An individual row, so it is never hidden: it stays in place and shows a
/// disabled field for a model with no notion of quality, which today means both
/// local engines. `SidebarView` documents the rule — hiding a row would move every
/// control below it whenever the model changed.
struct QualityView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var configStore = configStore

        let quality = controller.currentConstraints.quality

        Text("Quality", comment: "Label for the image quality picker")
            .sidebarLabelFormat()
        if quality.isEditable {
            Picker("", selection: $configStore.quality) {
                ForEach(quality.options) { option in
                    Text(verbatim: option.displayName).tag(option)
                }
            }
            .labelsHidden()
        } else if let pinned = quality.pinnedOption {
            // Shown disabled rather than as a one-item picker, for the same reason
            // a pinned step count is: seeing the value explains the behaviour.
            PinnedValueField(text: pinned.displayName)
        } else {
            UnsupportedValueField()
        }
    }
}

#Preview {
    QualityView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
