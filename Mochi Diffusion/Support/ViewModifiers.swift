//
//  ViewModifiers.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import SwiftUI

struct HelpTextFormat: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundColor(.secondary)
    }
}

struct SelectableTextFormat: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .foregroundColor(Color(nsColor: .textColor)) // Fixes dark text in dark mode SwiftUI bug
    }
}
