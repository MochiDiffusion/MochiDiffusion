// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

/// A control for selecting a value from a bounded linear range of values.
///
/// A slider consists of a handle that the user moves between two extremes of a linear “track”.
/// The ends of the track represent the minimum and maximum possible values. As the user moves
/// the handle, the slider updates its bound value.
///
/// The following example shows a slider bound to the value speed. As the slider updates this value,
/// a bound Text view shows the value updating.
/// ```
/// @State private var speed = 50.0
///
/// var body: some View {
///     // (Speed    |      50)
///     CompactSlider(value: $speed, in: 0...100) {
///         Text("Speed")
///         Spacer()
///         Text("\(Int(speed))")
///     }
/// }
/// ```
///
/// You can also use a step parameter to provide incremental steps along the path of the slider.
/// For example, if you have a slider with a range of 0 to 100, and you set the step value to 5,
/// the slider’s increments would be 0, 5, 10, and so on.
/// ```
/// @State private var speed = 50.0
///
/// var body: some View {
///     // 0 (      50      ) 100
///     HStack {
///         Text("0") // min value
///         CompactSlider(value: $speed, in: 0...100, step: 5) {
///             Text("\(Int(speed))") // selected value in the center
///         }
///         Text("100") // max value
///     }
/// }
/// ```
///
/// A slider can be created to represent a range of possible values.
/// ```
/// @State private var startTime = 8.0 // 08:00
/// @State private var endTime = 17.0 // 17:00
///
/// var body: some View {
///     // (Working hours  |-------|  8 - 17)
///     CompactSlider(
///         from: $startTime,
///         to: $endTime,
///         in: 0...24,
///         step: 1
///     ) {
///         Text("Working hours")
///         Spacer()
///         Text("\(Int(startTime)) - \(Int(endTime))")
///     }
/// }
/// ```
public struct CompactSlider<Value: BinaryFloatingPoint, ValueLabel: View>: View {

    @Environment(\.isEnabled) var isEnabled
    @Environment(\.compactSliderStyle) var compactSliderStyle
    @Environment(\.compactSliderDisabledHapticFeedback) var disabledHapticFeedback

    @Binding private var lowerValue: Value
    @Binding private var upperValue: Value
    private let bounds: ClosedRange<Value>
    private let step: Value
    let isRangeValues: Bool
    let direction: CompactSliderDirection
    let handleVisibility: HandleVisibility
    let scaleVisibility: ScaleVisibility
    let minHeight: CGFloat
    // Slider height would at least be 10 pt if we do not set this explicitly since we are using Rectangle/Color in HandleView implementation.
    // Explanation: When Color is used as a View, it would at least take 10 * 10 if we do not set its frame(width/height)/frame(maxWidth/maxHeight) explicitly.
    let maxHeight: CGFloat?
    let gestureOptions: Set<GestureOption>
    @Binding var state: CompactSliderState
    private let valueLabel: ValueLabel

    private var progressStep: Double = 0
    private var steps: Int = 0
    @State private var isLowerValueChangingInternally = false
    @State private var isUpperValueChangingInternally = false
    @State var isHovering = false
    @State var isDragging = false
    @State var lowerProgress: Double = 0
    @State var upperProgress: Double = 0
    @State private var dragLocationX: CGFloat = 0
    @State private var deltaLocationX: CGFloat = 0
    @State var adjustedDragLocationX: (lower: CGFloat, upper: CGFloat) = (0, 0)

    /// Creates a slider to select a value from a given bounds.
    ///
    /// The value of the created instance is equal to the position of the given value
    /// within bounds, mapped into 0...1.
    ///
    /// - Parameters:
    ///   - value: the selected value within bounds.
    ///   - bounds: the range of the valid values. Defaults to 0...1.
    ///   - step: the distance between each valid value.
    ///   - direction: the direction in which the slider will indicate the selected value.
    ///   - handleVisibility: the handle visibility determines the rules for showing the handle.
    ///   - scaleVisibility: the scale visibility determines the rules for showing the scale.
    ///   - minHeight: the slider minimum height.
    ///   - maxHeight: the slider maximum height (optional).
    ///   - gestureOptions: a set of drag gesture options: minimum drag distance, delayed touch, and high priority.
    ///   - state: the state of the slider with tracking information.
    ///   - valueLabel: a `View` that describes the purpose of the instance.
    ///                 This view is contained in the `HStack` with central alignment.
    public init(
        value: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        direction: CompactSliderDirection = .leading,
        handleVisibility: HandleVisibility = .standard,
        scaleVisibility: ScaleVisibility = .hovering,
        minHeight: CGFloat = .compactSliderMinHeight,
        maxHeight: CGFloat? = nil,
        gestureOptions: Set<GestureOption> = .default,
        state: Binding<CompactSliderState> = .constant(.inactive),
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        _lowerValue = value
        _upperValue = .constant(0)
        isRangeValues = false
        self.bounds = bounds
        self.step = step
        self.direction = direction
        self.handleVisibility = handleVisibility
        self.scaleVisibility = scaleVisibility
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.gestureOptions = gestureOptions
        _state = state
        self.valueLabel = valueLabel()
        let rangeLength = Double(bounds.length)

        guard rangeLength > 0 else { return }

        _lowerProgress = State(
            wrappedValue: Double(value.wrappedValue - bounds.lowerBound) / rangeLength)

        if step > 0 {
            progressStep = Double(step) / rangeLength
            steps = Int((rangeLength / Double(step)).rounded(.towardZero) - 1)
        }
    }

    /// Creates a slider to select a range of values from a given bounds.
    ///
    /// Values of the created instance is equal to the position of the given value
    /// within bounds, mapped into 0...1.
    ///
    /// - Parameters:
    ///   - lowerValue: the selected lower value within bounds.
    ///   - upperValue: the selected upper value within bounds.
    ///   - bounds: the range of the valid values. Defaults to 0...1.
    ///   - step: the distance between each valid value.
    ///   - handleVisibility: the handle visibility determines the rules for showing the handle.
    ///   - scaleVisibility: the scale visibility determines the rules for showing the scale.
    ///   - minHeight: the slider minimum height.
    ///   - maxHeight: the slider maximum height (optional).
    ///   - gestureOptions: a set of drag gesture options: minimum drag distance, delayed touch, and high priority.
    ///   - state: the state of the slider with tracking information.
    ///   - valueLabel: a `View` that describes the purpose of the instance.
    ///                 This view is contained in the `HStack` with central alignment.
    public init(
        from lowerValue: Binding<Value>,
        to upperValue: Binding<Value>,
        in bounds: ClosedRange<Value> = 0...1,
        step: Value = 0,
        handleVisibility: HandleVisibility = .standard,
        scaleVisibility: ScaleVisibility = .hovering,
        minHeight: CGFloat = .compactSliderMinHeight,
        maxHeight: CGFloat? = nil,
        gestureOptions: Set<GestureOption> = .default,
        state: Binding<CompactSliderState> = .constant(.inactive),
        @ViewBuilder valueLabel: () -> ValueLabel
    ) {
        _lowerValue = lowerValue
        _upperValue = upperValue
        isRangeValues = true
        self.bounds = bounds
        self.step = step
        direction = .leading
        self.handleVisibility = handleVisibility
        self.scaleVisibility = scaleVisibility
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.gestureOptions = gestureOptions
        _state = state
        self.valueLabel = valueLabel()
        let rangeLength = Double(bounds.length)

        guard rangeLength > 0 else { return }

        _lowerProgress = State(
            wrappedValue: Double(lowerValue.wrappedValue - bounds.lowerBound) / rangeLength)
        _upperProgress = State(
            wrappedValue: Double(upperValue.wrappedValue - bounds.lowerBound) / rangeLength)

        if step > 0 {
            progressStep = Double(step) / rangeLength
            steps = Int((rangeLength / Double(step)).rounded(.towardZero) - 1)
        }
    }

    public var body: some View {
        compactSliderStyle
            .makeBody(
                configuration: CompactSliderStyleConfiguration(
                    direction: direction,
                    isRangeValues: isRangeValues,
                    isHovering: isHovering,
                    isDragging: isDragging,
                    lowerProgress: lowerProgress,
                    upperProgress: upperProgress,
                    label: .init(content: contentView)
                )
            )
            #if os(macOS) || os(iOS)
                .onHover {
                    isHovering = isEnabled && $0
                    updateState()
                }
                .onScrollWheel(isEnabled: gestureOptions.contains(.scrollWheel)) { delta in
                    guard isHovering, abs(delta.x) > abs(delta.y) else { return }

                    Task {
                        deltaLocationX = delta.x
                    }
                }
            #endif
            .dragGesture(
                options: gestureOptions,
                onChanged: {
                    isDragging = true
                    updateState()
                    dragLocationX = $0.location.x
                },
                onEnded: {
                    isDragging = false
                    updateState()
                    dragLocationX = $0.location.x
                }
            )
            .onChange(of: lowerProgress, perform: onLowerProgressChange)
            .onChange(of: upperProgress, perform: onUpperProgressChange)
            .onChange(of: lowerValue, perform: onLowerValueChange)
            .onChange(of: upperValue, perform: onUpperValueChange)
            .animation(nil, value: lowerValue)
            .animation(nil, value: upperValue)
    }

    private var contentView: some View {
        ZStack {
            GeometryReader { proxy in
                ZStack {
                    progressView(in: proxy.size)

                    if !handleVisibility.isHidden,
                        handleVisibility.isAlways || isHovering || isDragging
                    {
                        progressHandleView(lowerProgress, size: proxy.size)

                        if !handleVisibility.isHidden, isRangeValues {
                            progressHandleView(upperProgress, size: proxy.size)
                        }

                        if isScaleVisible {
                            ScaleView(steps: steps)
                                .frame(height: proxy.size.height, alignment: .top)
                        }
                    } else if isRangeValues, abs(upperProgress - lowerProgress) < 0.01 {
                        progressHandleView(lowerProgress, size: proxy.size)
                    } else if direction == .center, abs(lowerProgress - 0.5) < 0.02 {
                        progressHandleView(lowerProgress, size: proxy.size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onChange(of: dragLocationX) { onDragLocationXChange($0, size: proxy.size) }
                .onChange(of: deltaLocationX) { onDeltaLocationXChange($0, size: proxy.size) }
            }

            HStack { valueLabel }
                .padding(.horizontal, .labelPadding)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isScaleVisible: Bool {
        if scaleVisibility == .hidden {
            return false
        }

        if scaleVisibility == .always {
            return true
        }

        return isHovering || isDragging
    }
}

// MARK: - Dragging

extension CompactSlider {

    fileprivate func onDragLocationXChange(_ newValue: CGFloat, size: CGSize) {
        guard !bounds.isEmpty, size.width > 0 else { return }

        updateProgress(max(0, min(1, newValue / size.width)))
    }

    fileprivate func onDeltaLocationXChange(_ newDelta: CGFloat, size: CGSize) {
        guard !bounds.isEmpty, size.width > 0 else { return }

        let deltaProgressStep = progressStep * (newDelta.sign == .minus ? -0.5 : 0.5)
        let newProgress = max(0, min(1, lowerProgress + newDelta / size.width + deltaProgressStep))
        updateProgress(newProgress)
    }

    fileprivate func updateProgress(_ newValue: Double) {
        let isProgress2Nearest: Bool

        // Check which progress is closest and should be in focus.
        if abs(upperProgress - lowerProgress) < 0.01 {
            isProgress2Nearest = newValue > upperProgress
        } else {
            isProgress2Nearest =
                isRangeValues && abs(lowerProgress - newValue) > abs(upperProgress - newValue)
        }

        guard progressStep > 0 else {
            if isProgress2Nearest {
                if upperProgress != newValue {
                    upperProgress = newValue

                    if upperProgress == 1 {
                        HapticFeedback.vibrate(disabledHapticFeedback)
                    }
                }
            } else if lowerProgress != newValue {
                lowerProgress = newValue

                if lowerProgress == 0 || lowerProgress == 1 {
                    HapticFeedback.vibrate(disabledHapticFeedback)
                }
            }

            return
        }

        let rounded = (newValue / progressStep).rounded() * progressStep

        if isProgress2Nearest {
            if rounded != upperProgress {
                upperProgress = rounded
                HapticFeedback.vibrate(disabledHapticFeedback)
            }
        } else if rounded != lowerProgress {
            lowerProgress = rounded
            HapticFeedback.vibrate(disabledHapticFeedback)
        }
    }

    fileprivate func onLowerProgressChange(_ newValue: Double) {
        isLowerValueChangingInternally = true
        lowerValue = convertProgressToValue(newValue)
        DispatchQueue.main.async { isLowerValueChangingInternally = false }
    }

    fileprivate func onUpperProgressChange(_ newValue: Double) {
        isUpperValueChangingInternally = true
        upperValue = convertProgressToValue(newValue)
        DispatchQueue.main.async { isUpperValueChangingInternally = false }
    }

    fileprivate func convertProgressToValue(_ newValue: Double) -> Value {
        let value = bounds.lowerBound + Value(newValue) * bounds.length
        return step > 0 ? (value / step).rounded() * step : value
    }

    fileprivate func onLowerValueChange(_ newValue: Value) {
        if isLowerValueChangingInternally { return }
        lowerProgress = convertValueToProgress(newValue)
    }

    fileprivate func onUpperValueChange(_ newValue: Value) {
        if isUpperValueChangingInternally { return }
        upperProgress = convertValueToProgress(newValue)
    }

    fileprivate func convertValueToProgress(_ newValue: Value) -> Double {
        let length = Double(bounds.length)
        return length != 0 ? Double(newValue - bounds.lowerBound) / length : 0
    }
}

// MARK: - Direction

/// A direction in which the slider will indicate the selected value.
public enum CompactSliderDirection {
    /// The selected value will be indicated from the lower left-hand area of the boundary.
    case leading
    /// The selected value will be indicated from the centre.
    case center
    /// The selected value will be indicated from the upper right-hand area of the boundary.
    case trailing
}

// MARK: - Range

extension ClosedRange where Bound: BinaryFloatingPoint {
    fileprivate var length: Bound { upperBound - lowerBound }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 16) {
        Text("CompactSlider")
            .font(.title.bold())

        Group {
            // 1. The default case.
            CompactSlider(value: .constant(0.5)) {
                Text("Default (leading)")
                Spacer()
                Text("0.5")
            }

            // Handle in the centre for better representation of negative values.
            // 2.1. The value is 0, which should show the handle as there is no value to show.
            CompactSlider(value: .constant(0.0), in: -1.0...1.0, direction: .center) {
                Text("Center -1.0...1.0")
                Spacer()
                Text("0.0")
            }

            // 2.2. When the value is not 0, the value can be shown with a rectangle.
            CompactSlider(value: .constant(0.3), in: -1.0...1.0, direction: .center) {
                Text("Center -1.0...1.0")
                Spacer()
                Text("0.3")
            }

            // 3. The value is filled in on the right-hand side.
            CompactSlider(value: .constant(0.3), direction: .trailing) {
                Text("Trailing")
                Spacer()
                Text("0.3")
            }

            Divider()

            // 4. Set a range of values in specific step to change.
            CompactSlider(value: .constant(70), in: 0...200, step: 10) {
                Text("Snapped")
                Spacer()
                Text("70")
            }

            // 4. Set a range of values in specific step to change from the center.
            CompactSlider(value: .constant(0.0), in: -10...10, step: 1, direction: .center) {
                Text("Center")
                Spacer()
                Text("0.0")
            }
            .compactSliderDisabledHapticFeedback(true)
        }

        Divider()

        // Prominent style.
        Group {
            CompactSlider(value: .constant(0.5)) {
                Text("Default")
                Spacer()
                Text("0.5")
            }
            .compactSliderStyle(
                .prominent(
                    lowerColor: .purple,
                    upperColor: .pink,
                    useGradientBackground: true
                )
            )

            // Get the range of values.
            VStack(spacing: 16) {
                CompactSlider(from: .constant(0.4), to: .constant(0.7)) {
                    Text("Range")
                    Spacer()
                    Text("0.2 - 0.7")
                }

                // Switch back to the `.default` style.
                CompactSlider(from: .constant(0.4), to: .constant(0.7)) {
                    Text("Range")
                    Spacer()
                    Text("0.2 - 0.7")
                }
                .compactSliderStyle(.default)
            }
            .compactSliderStyle(
                .prominent(
                    lowerColor: .green,
                    upperColor: .yellow,
                    useGradientBackground: true
                )
            )
        }
    }
    .padding()
    #if os(macOS)
        .frame(width: 600, height: 500, alignment: .top)
    #endif
}
