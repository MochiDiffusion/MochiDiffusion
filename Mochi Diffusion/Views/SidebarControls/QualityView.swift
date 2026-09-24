//
//  QualityView.swift
//  Mochi Diffusion
//

import SwiftUI

/// Picks how much effort a model should spend on an image.
///
/// Never hidden: for a model with no notion of quality it shows a disabled field,
/// so the controls below keep their positions when the model changes.
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
