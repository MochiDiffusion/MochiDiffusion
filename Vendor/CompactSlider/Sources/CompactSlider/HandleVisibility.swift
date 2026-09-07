// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

extension CompactSlider {
    /// A handle visibility determines the rules for showing the handle.
    public enum HandleVisibility {
        /// Shows the handle when hovering.
        case hovering(width: CGFloat)
        /// Always shows the handle.
        case always(width: CGFloat)
        /// Never shows the handle.
        case hidden

        /// Default value.
        public static var standard: HandleVisibility {
            #if os(macOS)
                .hovering(width: 3)
            #else
                .always(width: 3)
            #endif
        }

        var isHovering: Bool {
            if case .hovering = self {
                return true
            }

            return false
        }

        var isAlways: Bool {
            if case .always = self {
                return true
            }

            return false
        }

        var isHidden: Bool {
            if case .hidden = self {
                return true
            }

            return false
        }

        var width: CGFloat {
            switch self {
            case .hovering(let width),
                .always(let width):
                return width
            case .hidden:
                return 0
            }
        }
    }
}
