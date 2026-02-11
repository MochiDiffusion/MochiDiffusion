//
//  SizeView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct NumericTextField: View {
    @Binding var value: Int
    let bounds: ClosedRange<Int>
    let step: Int
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(value: Binding<Int>, bounds: ClosedRange<Int>, step: Int) {
        self._value = value
        self.bounds = bounds
        self.step = step
        self._text = State(initialValue: String(value.wrappedValue))
    }

    func correct(_ input: Int) -> Int {
        let clamped = min(max(input, bounds.lowerBound), bounds.upperBound)
        let snapped =
            bounds.lowerBound
            + Int(round(Double(clamped - bounds.lowerBound) / Double(step))) * step
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }

    var body: some View {
        TextField("", text: $text)
            .frame(width: 60)
            .multilineTextAlignment(.leading)
            .focused($isFocused)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, newValue in text = String(newValue) }
            .onSubmit(commit)
            .onChange(of: isFocused) { _, newFocus in if !newFocus { commit() } }
            .onReceive(text.publisher.collect()) { _ in
                // Allow digits only
                let filtered = text.filter { $0.isNumber }
                if text != filtered { text = filtered }
            }
    }
    func commit() {
        if let input = Int(text) {
            let valid = correct(input)
            value = valid
            text = String(valid)
        } else {
            text = String(value)
        }
    }
}

struct SizeView: View {
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    let minSize = 64, maxSize = 1792, step = 16

    var body: some View {
        @Bindable var configStore = configStore

        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(
                    "Width:",
                    comment: "Label for image width picker"
                )
                NumericTextField(value: $configStore.width, bounds: minSize...maxSize, step: step)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    let w = configStore.width
                    configStore.width = configStore.height
                    configStore.height = w
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .imageScale(.medium)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Swap width and height")
            .buttonStyle(.borderless)

            VStack(alignment: .leading) {
                Text(
                    "Height:",
                    comment: "Label for image height picker"
                )
                NumericTextField(value: $configStore.height, bounds: minSize...maxSize, step: step)
            }
        }
    }
}

#Preview {
    SizeView()
        .environment(ConfigStore())
}
