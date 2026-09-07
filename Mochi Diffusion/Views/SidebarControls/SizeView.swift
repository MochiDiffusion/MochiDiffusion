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
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    /// The size the model will produce, which for a fixed-size model is not
    /// whatever the sidebar has been left set to.
    private var resolvedSize: CGSize {
        controller.currentConstraints.size.resolved(
            CGSize(width: configStore.width, height: configStore.height)
        )
    }

    /// Whether swapping would do anything: either the size is freeform, or the
    /// engine has a model for the flipped orientation. A fixed-size model with no
    /// sibling has nothing to swap to.
    ///
    /// Disables the button rather than removing it. The two fields keep their
    /// positions across every model that way — a button that came and went moved
    /// them relative to each other and to the sidebar's edges.
    private var canSwap: Bool {
        controller.canSetSize(width: Int(resolvedSize.height), height: Int(resolvedSize.width))
    }

    var body: some View {
        let size = controller.currentConstraints.size

        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text(
                    "Width:",
                    comment: "Label for image width picker"
                )
                if let bounds = size.bounds, let step = size.step {
                    NumericTextField(
                        value: Binding(
                            get: { Int(resolvedSize.width) },
                            set: { configStore.width = $0 }
                        ),
                        bounds: bounds,
                        step: step
                    )
                } else {
                    PinnedValueField(text: String(Int(resolvedSize.width)))
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    // Routed through the controller, which asks the engine
                    // whether a size means a different model. For a freeform
                    // size it just writes the two numbers back.
                    controller.setSize(
                        width: Int(resolvedSize.height),
                        height: Int(resolvedSize.width)
                    )
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
            .disabled(!canSwap)

            VStack(alignment: .leading) {
                Text(
                    "Height:",
                    comment: "Label for image height picker"
                )
                if let bounds = size.bounds, let step = size.step {
                    NumericTextField(
                        value: Binding(
                            get: { Int(resolvedSize.height) },
                            set: { configStore.height = $0 }
                        ),
                        bounds: bounds,
                        step: step
                    )
                } else {
                    PinnedValueField(text: String(Int(resolvedSize.height)))
                }
            }
        }
    }
}
