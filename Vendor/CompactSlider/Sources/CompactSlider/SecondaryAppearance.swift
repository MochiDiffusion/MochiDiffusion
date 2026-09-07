// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

struct SecondaryAppearance {

    struct ProgressFillStyle {
        let fill: (Rectangle) -> AnyView

        init(_ fill: @escaping (Rectangle) -> AnyView) {
            self.fill = fill
        }
    }

    var progressFillStyle: ProgressFillStyle
    var focusedProgressFillStyle: ProgressFillStyle
    var handleColor: Color
    var scaleColor: Color
    var secondaryScaleColor: Color

}

struct CompactSliderSecondaryAppearanceKey: EnvironmentKey {
    static var defaultValue = SecondaryAppearance(
        progressFillStyle: .init {
            $0.fill(
                Color.label.opacity(CompactSliderDouble.progressOpacity)
            )
            .eraseToAnyView
        },
        focusedProgressFillStyle: .init {
            $0.fill(
                Color.accentColor.opacity(CompactSliderDouble.focusedProgressOpacity)
            )
            .eraseToAnyView
        },
        handleColor: Color.label.opacity(CompactSliderDouble.handleOpacity),
        scaleColor: Color.label.opacity(CompactSliderDouble.scaleOpacity),
        secondaryScaleColor: Color.label.opacity(CompactSliderDouble.secondaryScaleOpacity)
    )
}

extension EnvironmentValues {
    var compactSliderSecondaryAppearance: SecondaryAppearance {
        get { self[CompactSliderSecondaryAppearanceKey.self] }
        set { self[CompactSliderSecondaryAppearanceKey.self] = newValue }
    }
}

// MARK: - View Extension

extension View {

    /// Sets the colors for the secondary slider elements based on a given color and different opacity for each element.
    ///
    /// - Note: The exception to this is the `focusedProgressOpacity` parameter, which sets the opacity for the accent color.
    ///
    /// - Parameters:
    ///   - color: the secondary color.
    ///   - progressOpacity: the opacity for the progress view based on the secondary color.
    ///   - focusedProgressOpacity: the opacity for the focused progress view based on the accent color.
    ///   - handleOpacity: the opacity for the handle view based on the secondary color.
    ///   - scaleOpacity: the opacity for the scale view based on the secondary color.
    ///   - smallScaleOpacity: the opacity for the small scale view based on the secondary color.
    public func compactSliderSecondaryColor(
        _ color: Color,
        progressOpacity: Double? = nil,
        focusedProgressOpacity: Double? = nil,
        handleOpacity: Double? = nil,
        scaleOpacity: Double? = nil,
        secondaryScaleOpacity: Double? = nil
    ) -> some View {
        environment(
            \.compactSliderSecondaryAppearance,
            SecondaryAppearance(
                progressFillStyle: .init {
                    $0.fill(color.opacity(progressOpacity ?? CompactSliderDouble.progressOpacity))
                        .eraseToAnyView
                },
                focusedProgressFillStyle: .init {
                    $0.fill(
                        color.opacity(
                            focusedProgressOpacity ?? CompactSliderDouble.focusedProgressOpacity)
                    )
                    .eraseToAnyView
                },
                handleColor: color.opacity(handleOpacity ?? CompactSliderDouble.handleOpacity),
                scaleColor: color.opacity(scaleOpacity ?? CompactSliderDouble.scaleOpacity),
                secondaryScaleColor: color.opacity(
                    secondaryScaleOpacity ?? CompactSliderDouble.secondaryScaleOpacity)
            )
        )
    }

    /// Sets the colors for the secondary slider elements.
    /// - Parameters:
    ///   - progressColor: the default progress view color.
    ///   - focusedProgressColor: the focused progress view color.
    ///   - handleColor: the handle view color.
    ///   - scaleColor: the scale color.
    ///   - secondaryScaleColor: the secondary scale color.
    public func compactSliderSecondaryColor(
        progressColor: Color? = nil,
        focusedProgressColor: Color? = nil,
        handleColor: Color? = nil,
        scaleColor: Color? = nil,
        secondaryScaleColor: Color? = nil
    ) -> some View {
        environment(
            \.compactSliderSecondaryAppearance,
            SecondaryAppearance(
                progressFillStyle: .init {
                    $0.fill(progressColor ?? .label.opacity(CompactSliderDouble.progressOpacity))
                        .eraseToAnyView
                },
                focusedProgressFillStyle: .init {
                    $0.fill(
                        focusedProgressColor
                            ?? .label.opacity(CompactSliderDouble.focusedProgressOpacity)
                    )
                    .eraseToAnyView
                },
                handleColor: handleColor ?? .label.opacity(CompactSliderDouble.handleOpacity),
                scaleColor: scaleColor ?? .label.opacity(CompactSliderDouble.scaleOpacity),
                secondaryScaleColor: secondaryScaleColor
                    ?? .label.opacity(CompactSliderDouble.secondaryScaleOpacity)
            )
        )
    }

    /// Sets the appearance for the secondary slider elements.
    /// - Parameters:
    ///   - progressShapeStyle: the default shape style for the progress view.
    ///   - focusedProgressShapeStyle: the shape style for the focused progress view.
    ///   - handleColor: the handle view color.
    ///   - scaleColor: the scale color.
    ///   - secondaryScaleColor: the secondary scale color.
    public func compactSliderSecondaryAppearance<S1: ShapeStyle, S2: ShapeStyle>(
        progressShapeStyle: S1,
        focusedProgressShapeStyle: S2,
        handleColor: Color? = nil,
        scaleColor: Color? = nil,
        secondaryScaleColor: Color? = nil
    ) -> some View {
        environment(
            \.compactSliderSecondaryAppearance,
            SecondaryAppearance(
                progressFillStyle: .init { $0.fill(progressShapeStyle).eraseToAnyView },
                focusedProgressFillStyle: .init {
                    $0.fill(focusedProgressShapeStyle).eraseToAnyView
                },
                handleColor: handleColor ?? .label.opacity(CompactSliderDouble.handleOpacity),
                scaleColor: scaleColor ?? .label.opacity(CompactSliderDouble.scaleOpacity),
                secondaryScaleColor: secondaryScaleColor
                    ?? .label.opacity(CompactSliderDouble.secondaryScaleOpacity)
            )
        )
    }
}

enum CompactSliderDouble {
    static let progressOpacity: Double = 0.075
    static let focusedProgressOpacity: Double = 0.3
    static let handleOpacity: Double = 0.2
    static let scaleOpacity: Double = 0.8
    static let secondaryScaleOpacity: Double = 0.3
}

extension Rectangle {
    func fill(_ appearance: SecondaryAppearance.ProgressFillStyle) -> some View {
        appearance.fill(self)
    }
}

extension View {
    var eraseToAnyView: AnyView {
        AnyView(self)
    }
}
