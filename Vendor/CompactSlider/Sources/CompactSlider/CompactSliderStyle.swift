// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

/// A type that applies standard interaction behaviour and a custom appearance to all sliders within a view hierarchy.
///
/// To configure the current slider style for a view hierarchy, use the `compactSliderStyle(_:)` modifier.
public protocol CompactSliderStyle {
    associatedtype Body: View
    typealias Configuration = CompactSliderStyleConfiguration

    func makeBody(configuration: Self.Configuration) -> Self.Body
}

// MARK: - Configuration

/// Configuration for creating a style for the slider.
public struct CompactSliderStyleConfiguration {

    public struct Label: View {
        public let body: AnyView

        init<Content: View>(content: Content) {
            body = AnyView(content)
        }
    }

    /// A direction in which the slider will indicate the selected value.
    public let direction: CompactSliderDirection
    /// True if the slider uses a range of values.
    public let isRangeValues: Bool
    /// True, when hovering the slider.
    public let isHovering: Bool
    /// True, when dragging the slider.
    public let isDragging: Bool
    /// The progress represents the position of the selected value within bounds, mapped into 0...1.
    /// This progress should be used to track a single value or a lower value for a range of values.
    public let lowerProgress: Double
    /// The progress represents the position of the selected value within bounds, mapped into 0...1.
    /// This progress should only be used to track the upper value for the range of values.
    public let upperProgress: Double
    /// A view that describes the effect of calling the slider’s action.
    public let label: Label
}

// MARK: - Environment

struct CompactSliderStyleKey: EnvironmentKey {
    static var defaultValue = AnyCompactSliderStyle(DefaultCompactSliderStyle())
}

extension EnvironmentValues {
    var compactSliderStyle: AnyCompactSliderStyle {
        get { self[CompactSliderStyleKey.self] }
        set { self[CompactSliderStyleKey.self] = newValue }
    }
}

struct AnyCompactSliderStyle: CompactSliderStyle {
    private let _makeBody: (Configuration) -> AnyView

    init<Style: CompactSliderStyle>(_ style: Style) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        _makeBody(configuration)
    }
}

// MARK: - View Extension

extension View {
    /// Sets the style for sliders within this view to a slider style with a custom appearance
    /// and custom interaction behaviour.
    public func compactSliderStyle<Style: CompactSliderStyle>(_ style: Style) -> some View {
        environment(\.compactSliderStyle, AnyCompactSliderStyle(style))
    }
}
