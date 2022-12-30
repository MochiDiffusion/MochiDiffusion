//
//  ViewModifiers.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/30/22.
//

import SwiftUI

extension Text {
    func helpTextFormat() -> some View {
        modifier(HelpTextFormat())
    }
    
    func selectableTextFormat() -> some View {
        modifier(SelectableTextFormat())
    }
}

private struct HelpTextFormat: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.callout)
            .foregroundColor(.secondary)
    }
}

private struct SelectableTextFormat: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    
    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .foregroundColor(colorScheme == .dark ? .white : .black) // Fixes dark text in dark mode SwiftUI bug
    }
}
