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
    private let bounds: ClosedRange<Double>
    private let step: Double
    private let fractionLength: Int
    private let strictUpperBound: Bool

    init(value: Binding<Double>, bounds: ClosedRange<Double>, step: Decimal, strictUpperBound: Bool = true) {
        _value = value
        self.bounds = bounds
        self.step = (step as NSDecimalNumber).doubleValue
        self.fractionLength = max(0, -step.exponent)
        self.strictUpperBound = strictUpperBound
    }

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
                                var newValue = max(doubleValue, bounds.lowerBound)
                                if strictUpperBound {
                                    newValue = min(newValue, bounds.upperBound)
                                }
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
