// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

/// Represents the current slider state
public struct CompactSliderState {
    /// Returns true when the cursor is over the slider (macOS, iPadOS).
    public let isHovering: Bool
    /// Returns true when dragging the handle.
    public let isDragging: Bool
    /// The progress represents the position of the given value within bounds, mapped into 0...1.
    /// This progress should be used to track a single value or a lower value for a range of values.
    public let lowerProgress: Double
    /// The progress represents the position of the given value within bounds, mapped into 0...1.
    /// This progress should only be used to track the upper value for the range of values.
    public let upperProgress: Double
    /// Position of the handle while dragging it.
    public let dragLocationX: (lower: CGFloat, upper: CGFloat)

    /// A flag for internal usage.
    var isActive = true

    /// Initial state for the state.
    public static let zero = CompactSliderState(
        isHovering: false,
        isDragging: false,
        lowerProgress: 0,
        upperProgress: 0,
        dragLocationX: (0, 0)
    )

    /// Inactive state, which will be ignored for updates.
    public static let inactive: CompactSliderState = {
        var state = CompactSliderState(
            isHovering: false,
            isDragging: false,
            lowerProgress: 0,
            upperProgress: 0,
            dragLocationX: (0, 0)
        )

        state.isActive = false
        return state
    }()
}

// MARK: - Slider

extension CompactSlider {
    func updateState() {
        guard state.isActive else { return }

        state = .init(
            isHovering: isHovering,
            isDragging: isDragging,
            lowerProgress: lowerProgress,
            upperProgress: upperProgress,
            dragLocationX: adjustedDragLocationX
        )
    }
}
