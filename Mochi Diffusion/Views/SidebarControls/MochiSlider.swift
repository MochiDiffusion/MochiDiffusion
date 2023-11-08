//
//  MochiSlider.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-08.
//

import CompactSlider
import SwiftUI

struct MochiSlider: View {

    @EnvironmentObject private var focusCon: FocusController

    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let step: Double
    let fractionLength: Int

    @State private var text: String = ""
    @State private var isEditable = false
    @FocusState private var focusedSlider: UUID?
    private let id = UUID()

    var body: some View {
        CompactSlider(value: $value, in: bounds, step: step) {
            if isEditable {
                TextField("", text: $text)
                    .monospacedDigit()
                    .textFieldStyle(PlainTextFieldStyle())
                    .focused($focusedSlider, equals: self.id)
                    .onChange(of: _focusedSlider.wrappedValue) { newValue in
                        if newValue == self.id {
                            focusCon.focusedSliderField = newValue
                        } else {
                            if let doubleValue = Double(text) {
                                let newValue = min(max(doubleValue, bounds.lowerBound), bounds.upperBound)
                                self.value = newValue
                            }
                            self.isEditable = false
                        }
                    }
                    .onChange(of: focusCon.focusedSliderField) { newValue in
                        self.focusedSlider = newValue
                    }
                    .onSubmit {
                        self.focusedSlider = nil
                    }
                    .onExitCommand {
                        self.text = ""
                        self.focusedSlider = nil
                    }
            } else {
                Text(verbatim: "\(value.formatted(.number.precision(.fractionLength(fractionLength))))")
                    .monospacedDigit()
                    .gesture(TapGesture(count: 2).onEnded {
                        self.text = value.formatted(.number.precision(.fractionLength(fractionLength)))
                        self.isEditable = true
                        self.focusedSlider = self.id
                    })
            }
            Spacer()
        }
        .compactSliderStyle(.mochi)
    }
}
