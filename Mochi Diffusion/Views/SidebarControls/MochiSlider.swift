//
//  MochiSlider.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-08.
//

import CompactSlider
import SwiftUI

struct MochiSlider: View {
    @Environment(FocusController.self) private var focusCon: FocusController
    @Binding var value: Double
    private let bounds: ClosedRange<Double>
    private let step: Double
    private let fractionLength: Int
    private let strictUpperBound: Bool

    init(
        value: Binding<Double>, bounds: ClosedRange<Double>, step: Decimal,
        strictUpperBound: Bool = true
    ) {
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

    func stringToDouble(_ string: String) -> Double? {
        if let doubleValue = Double(string.replacingOccurrences(of: ",", with: ".")) {
            var newValue = max(doubleValue, bounds.lowerBound)
            if strictUpperBound {
                newValue = min(newValue, bounds.upperBound)
            }
            return newValue
        }
        return nil
    }

    var body: some View {
        CompactSlider(value: $value, in: bounds, step: step) {
            if isEditable {
                TextField("", text: $text)
                    .focused($focusedSlider, equals: self.id)
            } else {
                Text(text)
                    .padding(.leading, 4)
                    .padding(.bottom, 1)
                    .gesture(
                        TapGesture(count: 1).onEnded {
                            self.isEditable = true
                            self.focusedSlider = self.id
                        }
                    )
                    .onHover { inside in
                        if inside {
                            NSCursor.iBeam.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
            Spacer()
        }
        .compactSliderStyle(.mochi)
        .onAppear {
            self.text = value.formatted(.number.precision(.fractionLength(fractionLength)))
        }

        // MARK: onChange

        .onChange(of: self.text) {
            guard let newDouble = stringToDouble(self.text) else { return }

            let roundedDouble = Double(round(newDouble / step) * step)
            self.value = roundedDouble
        }

        /// Only update if the value actually changes, to avoid changing text while user is editing it
        /// otherwise, e.g. sequence of events of user trying to set guidance scale to 6.5:
        ///   1. User types "6"
        ///   2. `.onChange(of: self.text)` updates `value` to 6.0
        ///   3. `.onChange(of: self.value)` updates `text` to "6.0"
        ///   4. User types ".5"
        ///   5. `text` is "6.0.5"
        .onChange(of: self.value) {
            guard let textDouble = stringToDouble(self.text) else { return }

            // ignore insignificant differences caused by float imprecision
            let significantDifference = step / 2
            if max(textDouble, self.value) - min(textDouble, self.value) > significantDifference {
                self.text = self.value.formatted(.number.precision(.fractionLength(fractionLength)))
            }
        }

        // MARK: Focus

        .onChange(of: focusCon.focusedSliderField) {
            self.focusedSlider = focusCon.focusedSliderField
        }
        .onChange(of: _focusedSlider.wrappedValue) {
            if _focusedSlider.wrappedValue == self.id {
                focusCon.focusedSliderField = _focusedSlider.wrappedValue
            } else {
                self.text = value.formatted(.number.precision(.fractionLength(fractionLength)))
                self.isEditable = false
            }
        }
        .onSubmit {
            self.focusedSlider = nil
            self.isEditable = false
        }
        .onExitCommand {
            self.focusedSlider = nil
            self.isEditable = false
        }
    }
}
