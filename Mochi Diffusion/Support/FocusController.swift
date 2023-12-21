//
//  FocusController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/26/23.
//

import Foundation
import SwiftUI

@MainActor
final class FocusController: ObservableObject {

    static let shared = FocusController()

    @Published var promptFieldIsFocused = false

    @Published var negativePromptFieldIsFocused = false

    @Published var seedFieldIsFocused = false

    @Published var focusedSliderField: UUID?

    var isTextFieldFocused: Bool {
        negativePromptFieldIsFocused || promptFieldIsFocused || seedFieldIsFocused || (focusedSliderField != nil)
    }

    /// Remove focus from all fields.
    func removeAllFocus() {
        promptFieldIsFocused = false
        negativePromptFieldIsFocused = false
        seedFieldIsFocused = false
        focusedSliderField = nil
    }
}
