import SwiftUI

struct DrawThingsLoRAView: View {
    @Environment(GenerationController.self) private var controller

    var body: some View {
        if let model = controller.currentModel as? DrawThingsModel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("LoRAs").sidebarLabelFormat()
                    Spacer()
                    Menu("Add LoRA") {
                        ForEach(
                            model.loras.filter { lora in
                                !controller.drawThingsLoRAs.contains { $0.file == lora.file }
                            }
                        ) { lora in
                            Button(lora.name) {
                                controller.drawThingsLoRAs.append(
                                    LoRASelection(file: lora.file, weight: lora.defaultWeight)
                                )
                            }
                        }
                    }
                    .disabled(model.loras.count == controller.drawThingsLoRAs.count)
                }
                if model.loras.isEmpty {
                    Text("No compatible LoRAs published by this server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(controller.drawThingsLoRAs) { selection in
                    if let lora = model.loras.first(where: { $0.file == selection.file }) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(lora.name).lineLimit(2).help(lora.file)
                                Spacer()
                                Button {
                                    controller.drawThingsLoRAs.removeAll { $0.file == lora.file }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(lora.name)")
                            }
                            HStack {
                                Text("Weight").font(.caption)
                                if lora.weightRange.lowerBound < lora.weightRange.upperBound {
                                    Slider(
                                        value: weight(for: lora), in: lora.weightRange, step: 0.05
                                    )
                                    .accessibilityLabel("\(lora.name) weight")
                                }
                                Text(
                                    selection.weight, format: .number.precision(.fractionLength(2))
                                )
                                .monospacedDigit().frame(width: 42, alignment: .trailing)
                            }
                            if !lora.trigger.isEmpty {
                                Text("Trigger words: \(lora.trigger)")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(
                                        .enabled)
                            }
                        }
                    }
                }
            }
            Spacer().frame(height: 6)
        }
    }

    private func weight(for lora: DrawThingsLoRA) -> Binding<Float> {
        Binding(
            get: {
                controller.drawThingsLoRAs.first { $0.file == lora.file }?.weight
                    ?? lora.defaultWeight
            },
            set: { value in
                guard
                    let index = controller.drawThingsLoRAs.firstIndex(where: {
                        $0.file == lora.file
                    })
                else { return }
                controller.drawThingsLoRAs[index].weight = value
            }
        )
    }
}
