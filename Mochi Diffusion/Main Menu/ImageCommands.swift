//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    @ObservedObject var controller: ImageController
    @ObservedObject var generator: ImageGenerator
    @ObservedObject var store: ImageStore
    @ObservedObject var focusController: FocusController

    private var isTextFieldFocused: Bool {
        $focusController.negativePromptFieldIsFocused.wrappedValue || $focusController.promptFieldIsFocused.wrappedValue || $focusController.seedFieldIsFocused.wrappedValue
    }

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                if case .running = generator.state {
                    Button {
                        Task { await ImageGenerator.shared.stopGenerate() }
                    } label: {
                        Text("Stop Generation")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                } else {
                    Button {
                        Task { await ImageController.shared.generate() }
                    } label: {
                        Text("Generate")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                    .disabled(controller.modelName.isEmpty)
                }
            }
            Section {
                Button {
                    Task { await ImageController.shared.selectNext() }
                } label: {
                    Text(
                        "Select Next",
                        comment: "Select next image in Gallery"
                    )
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.images.isEmpty || isTextFieldFocused)

                Button {
                    Task { await ImageController.shared.selectPrevious() }
                } label: {
                    Text(
                        "Select Previous",
                        comment: "Select previous image in Gallery"
                    )
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.images.isEmpty || isTextFieldFocused)
            }
            Section {
                Button {
                    Task { await ImageController.shared.upscaleCurrentImage() }
                } label: {
                    Text(
                        "Convert to High Resolution",
                        comment: "Convert the current image to high resolution"
                    )
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(store.selected() == nil)

                Button {
                    Task { await ImageController.shared.quicklookCurrentImage() }
                } label: {
                    Text(
                        "Quick Look",
                        comment: "View current image using Quick Look"
                    )
                }
                .keyboardShortcut("L", modifiers: .command)
                .disabled(store.selected() == nil)
            }
            Section {
                Button {
                    Task { await ImageController.shared.removeCurrentImage() }
                } label: {
                    Text(
                        "Remove",
                        comment: "Remove image from the gallery"
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.selected() == nil || isTextFieldFocused)
            }
        }
    }
}
