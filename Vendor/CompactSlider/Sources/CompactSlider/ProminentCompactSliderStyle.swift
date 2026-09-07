// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

/// A slider style that applies prominent artwork based on the slider’s context.
public struct ProminentCompactSliderStyle: CompactSliderStyle {

    /// The color of the lower value within bounds.
    public let lowerColor: Color
    /// The color of the upper value within bounds.
    public let upperColor: Color
    /// Flag which allows the specified colours (`lowerColor`, `upperColor`) to be used for the gradient background.
    public var useGradientBackground: Bool = false
    /// The threshold to switch from `lowerColor` to `upperColor`.
    public var threshold: CGFloat = 0.5

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                Color.label.opacity(configuration.isHovering || configuration.isDragging ? 1 : 0.7)
            )
            .background(
                Color.label
                    .opacity(
                        useGradientBackground
                            && (configuration.isDragging || configuration.isHovering) ? 0 : 0.075
                    )
            )
            .background(
                // Erase to View to disambiguate View.opacity from ShapeStyle.opacity on newer SDKs.
                AnyView(
                    LinearGradient(
                        colors: [lowerColor, upperColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(
                    useGradientBackground && (configuration.isDragging || configuration.isHovering)
                        ? 0.2 : 0)
            )
            .accentColor(
                configuration.isRangeValues
                    ? (abs(configuration.upperProgress - threshold)
                        > abs(configuration.lowerProgress - threshold)
                        ? upperColor : lowerColor)
                    : configuration.lowerProgress > threshold ? upperColor : lowerColor
            )
            .clipShape(RoundedRectangle(cornerRadius: .cornerRadius))
    }
}

extension CompactSliderStyle where Self == ProminentCompactSliderStyle {
    /// A slider style that applies prominent artwork based on the slider’s context.
    public static func prominent(
        lowerColor: Color,
        upperColor: Color,
        useGradientBackground: Bool = false,
        threshold: CGFloat = 0.5
    ) -> Self {
        ProminentCompactSliderStyle(
            lowerColor: lowerColor,
            upperColor: upperColor,
            useGradientBackground: useGradientBackground,
            threshold: threshold
        )
    }
}
