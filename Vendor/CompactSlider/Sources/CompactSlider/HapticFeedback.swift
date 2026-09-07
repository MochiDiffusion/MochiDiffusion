// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

enum HapticFeedback {

    #if os(iOS)
        private static let feedbackGenerator: UISelectionFeedbackGenerator = {
            let generator = UISelectionFeedbackGenerator()
            generator.prepare()
            return generator
        }()
    #endif

    static func vibrate(_ disabled: Bool) {
        guard !disabled else { return }

        #if os(macOS)
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #elseif os(iOS)
            feedbackGenerator.selectionChanged()
            feedbackGenerator.prepare()
        #endif
    }
}

// MARK: - Environment

struct CompactSliderDisabledHapticFeedbackKey: EnvironmentKey {
    static var defaultValue = false
}

extension EnvironmentValues {
    var compactSliderDisabledHapticFeedback: Bool {
        get { self[CompactSliderDisabledHapticFeedbackKey.self] }
        set { self[CompactSliderDisabledHapticFeedbackKey.self] = newValue }
    }
}

// MARK: - View

extension View {
    /// Adds a condition that controls haptic feedback to the user.
    /// - Parameter disabled: a boolean value that determines whether users can receive haptic feedback.
    public func compactSliderDisabledHapticFeedback(_ disabled: Bool) -> some View {
        environment(\.compactSliderDisabledHapticFeedback, disabled)
    }
}
