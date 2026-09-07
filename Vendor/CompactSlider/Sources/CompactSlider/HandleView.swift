// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

struct HandleView: View {

    @Environment(\.compactSliderSecondaryAppearance) var secondaryAppearance

    let width: CGFloat
    let offsetX: CGFloat
    let isFocused: Bool

    var body: some View {
        Rectangle()
            .fill(isFocused ? Color.accentColor : secondaryAppearance.handleColor)
            .frame(width: width)
            .offset(x: offsetX)
    }
}

extension CompactSlider {
    func progressHandleView(_ progress: Double, size: CGSize) -> some View {
        Group {
            if handleVisibility.width > 0 {
                HandleView(
                    width: handleVisibility.width,
                    offsetX: (size.width - handleVisibility.width) * (progress - 0.5),
                    isFocused: isHovering || isDragging
                )
            }
        }
    }
}
