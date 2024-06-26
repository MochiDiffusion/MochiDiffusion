//
//  FocusController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/26/23.
//

import Foundation
import SwiftUI

@Observable public final class FocusController {

    static let shared = FocusController()

    var promptFieldIsFocused = false

    var negativePromptFieldIsFocused = false

    var seedFieldIsFocused = false

    var focusedSliderField: UUID?

    var isTextFieldFocused: Bool {
        negativePromptFieldIsFocused || promptFieldIsFocused || seedFieldIsFocused
            || (focusedSliderField != nil)
    }

    /// Remove focus from all fields.
    func removeAllFocus() {
        promptFieldIsFocused = false
        negativePromptFieldIsFocused = false
        seedFieldIsFocused = false
        focusedSliderField = nil
    }
}
