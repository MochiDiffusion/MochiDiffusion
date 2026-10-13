//
//  LoRAView.swift
//  Mochi Diffusion
//

import FilterablePicker
import SwiftUI

/// The saved LoRAs the selected model can use, with their weights, and a picker
/// to add more of the model's LoRAs.
struct LoRAView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        HStack {
            Text("LoRAs")
                .sidebarLabelFormat()
            Spacer()
            FilterablePicker(
                String(localized: "Add LoRA", comment: "Picker that adds a LoRA to the sidebar"),
                selection: addSelection,
                items: controller.addableLoRAs,
                title: \.name
            )
            .frame(maxWidth: 160)
            // With nothing left to add, the picker is hidden but keeps its space,
            // so the rows below do not move when it reappears.
            .opacity(controller.addableLoRAs.isEmpty ? 0 : 1)
            .disabled(controller.addableLoRAs.isEmpty)
            .accessibilityHidden(controller.addableLoRAs.isEmpty)
        }
        ForEach(controller.shownLoRAs, id: \.option.id) { option, selection in
            LoRARow(option: option, selection: selection)
        }
    }

    /// Always reads as the empty filename, which is no LoRA, so the picker keeps
    /// showing its label after each choice while the chosen LoRA moves below it.
    private var addSelection: Binding<String> {
        Binding(
            get: { "" },
            set: { file in
                guard let option = controller.addableLoRAs.first(where: { $0.file == file })
                else { return }
                controller.addLoRA(option)
            }
        )
    }
}

private struct LoRARow: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    let option: LoRAOption
    let selection: LoRASelection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: option.name)
                    .lineLimit(2)
                    .help(option.file)
                Spacer()
                Button {
                    controller.removeLoRA(file: option.file)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .help(
                    String(
                        localized: "Remove \(option.name)", comment: "Tooltip for removing a LoRA"))
            }
            if option.weightRange.lowerBound < option.weightRange.upperBound {
                // Draw Things treats the range as a suggestion, so a typed weight
                // beyond either end is kept.
                MochiSlider(
                    value: weight, bounds: option.weightRange, step: 0.05,
                    strictUpperBound: false, strictLowerBound: false)
            } else {
                PinnedValueField(
                    text: selection.weight.formatted(.number.precision(.fractionLength(2))))
            }
            if !option.triggerWords.isEmpty {
                Text("Trigger words: \(option.triggerWords)", comment: "A LoRA's trigger words")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var weight: Binding<Double> {
        Binding(
            get: { selection.weight },
            set: { controller.setLoRAWeight($0, file: option.file) }
        )
    }
}
