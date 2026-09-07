// The MIT License (MIT)
//
// Copyright (c) 2022 Alexey Bukhtin (github.com/buh).
//

import SwiftUI

extension CGFloat {

    /// The min height of the `CompactSlider`.
    public static let compactSliderMinHeight: CGFloat = {
        #if os(macOS)
            24
        #else
            44
        #endif
    }()

    static let labelPadding: CGFloat = {
        #if os(macOS)
            6
        #else
            12
        #endif
    }()

    static let cornerRadius: CGFloat = {
        #if os(macOS)
            4
        #else
            8
        #endif
    }()

    static let scaleLineWidth: CGFloat = 0.5

    static let scaleLength: CGFloat = {
        #if os(macOS)
            5
        #else
            10
        #endif
    }()

    static let secondaryScaleLength: CGFloat = {
        #if os(macOS)
            3
        #else
            6
        #endif
    }()
}
