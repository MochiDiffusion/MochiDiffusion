// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

/// The default slider style.
public struct DefaultCompactSliderStyle: CompactSliderStyle {
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(
                Color.label.opacity(configuration.isHovering || configuration.isDragging ? 1 : 0.7)
            )
            .background(Color.label.opacity(0.075))
            .clipShape(RoundedRectangle(cornerRadius: .cornerRadius))
    }
}

extension CompactSliderStyle where Self == DefaultCompactSliderStyle {
    public static var `default`: DefaultCompactSliderStyle { DefaultCompactSliderStyle() }
}
