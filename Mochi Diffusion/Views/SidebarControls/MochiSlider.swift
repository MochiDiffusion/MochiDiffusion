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
    @FocusState private var focusedSlider: UUID?
    private let id = UUID()

    func stringToDouble(_ string: String) -> Double? {
        if let doubleValue = Double(string) {
            var newValue = max(doubleValue, bounds.lowerBound)
            if strictUpperBound {
                newValue = min(newValue, bounds.upperBound)
            }
            return newValue
        }
        return nil
    }

    /// TextField overlays the slider, so the TextField frame should be as small as possible, to leave as much of the slider accessible as possible
    /// If the slider is not focused, the frame is tightly fit to the text
    /// If the slider is focused, the frame needs an M width affordance, to accomodate text entry
    /// The sequence of events upon text entry:
    ///   1. User presses key
    ///   2. TextField redraws its content within its frame
    ///   3. Binding updates `text`
    ///   4. `textFieldWidth` is recalculated
    ///   5. TextField frame is updated
    ///   6. TextField redraws its content within its frame
    /// Without the affordance the UI stutters because TextField draws its content differently when it doesn't fit in the frame
    private var textFieldSize: CGSize {
        let textSize = (text as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .body)])

        if focusedSlider != self.id {
            return textSize
        } else {
            let mWidth = ("M" as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .body)]).width
            return CGSize(width: textSize.width + mWidth, height: textSize.height)
        }
    }

    var body: some View {
        CompactSlider(value: $value, in: bounds, step: step) {
            TextField("", text: $text)
                .frame(width: textFieldSize.width, height: textFieldSize.height * 0.7)
                .textFieldStyle(PlainTextFieldStyle())
                .focused($focusedSlider, equals: self.id)
            Spacer()
        }

        .compactSliderStyle(.mochi)
        .onChange(of: focusCon.focusedSliderField) { newValue in
            self.focusedSlider = newValue
        }
        .onChange(of: _focusedSlider.wrappedValue) { newValue in
            if newValue == self.id {
                focusCon.focusedSliderField = newValue
            } else {
                self.text = value.formatted(.number.precision(.fractionLength(fractionLength)))
            }
        }
        .onSubmit {
            self.focusedSlider = nil
        }
        .onExitCommand {
            self.focusedSlider = nil
        }
        .onAppear {
            self.text = value.formatted(.number.precision(.fractionLength(fractionLength)))
        }
        .onChange(of: self.text) { newValue in
            guard let newDouble = stringToDouble(newValue) else { return }

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
        .onChange(of: self.value) { newValue in
            guard let textDouble = stringToDouble(self.text) else { return }

            let significantDifference = step / 2 // ignore insignificant differences caused by float imprecision
            if max(textDouble, newValue) - min(textDouble, newValue) > significantDifference {
                self.text = newValue.formatted(.number.precision(.fractionLength(fractionLength)))
                self.focusedSlider = nil
            }
        }
    }
}
