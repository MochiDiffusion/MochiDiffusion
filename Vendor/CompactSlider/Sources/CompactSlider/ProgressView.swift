// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

struct ProgressView: View {

    @Environment(\.compactSliderSecondaryAppearance) var secondaryAppearance

    let width: CGFloat
    let offsetX: CGFloat
    let isFocused: Bool

    var body: some View {
        Rectangle()
            .fill(
                isFocused
                    ? secondaryAppearance.focusedProgressFillStyle
                    : secondaryAppearance.progressFillStyle
            )
            .frame(width: width)
            .offset(x: offsetX)
    }
}

// MARK: - Slider

extension CompactSlider {

    func progressView(in size: CGSize) -> some View {
        ProgressView(
            width: progressWidth(size),
            offsetX: progressOffsetX(size),
            isFocused: isHovering || isDragging
        )
    }

    func progressWidth(_ size: CGSize) -> CGFloat {
        if isRangeValues {
            return size.width * abs(upperProgress - lowerProgress)
        }

        if direction == .trailing {
            return size.width * (1 - lowerProgress)
        }

        if direction == .center {
            return size.width * abs(0.5 - lowerProgress)
        }

        return size.width * lowerProgress
    }

    func progressOffsetX(_ size: CGSize) -> CGFloat {
        let width = progressWidth(size)

        if isRangeValues {
            let offset = size.width * ((1 - (upperProgress - lowerProgress)) / -2 + lowerProgress)

            DispatchQueue.main.async {
                adjustedDragLocationX = (offset - width / 2, offset + width / 2)
                updateState()
            }

            return offset
        }

        let offset: CGFloat

        if direction == .trailing {
            offset = size.width * lowerProgress / 2
        } else if direction == .center {
            offset = size.width * (lowerProgress - 0.5) / 2
        } else {
            offset = size.width * (1 - lowerProgress) / -2
        }

        DispatchQueue.main.async {
            adjustedDragLocationX = (offset + width / 2, 0)
            updateState()
        }

        return offset
    }
}
