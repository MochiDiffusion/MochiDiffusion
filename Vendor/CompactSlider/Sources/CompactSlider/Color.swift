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

extension Color {
    #if os(macOS)
        static let label = Color(NSColor.labelColor)
    #elseif os(watchOS)
        static let label = Color(UIColor.white)
    #else
        static let label = Color(UIColor.label)
    #endif
}
