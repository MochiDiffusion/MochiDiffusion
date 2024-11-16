//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    @ObservedObject var controller: ImageController
    var generator: ImageGenerator
    var store: ImageStore
    var focusController: FocusController

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                Button {
                    Task { await ImageController.shared.generate() }
                } label: {
                    if case .ready = ImageGenerator.shared.state {
                        Text(
                            "Generate",
                            comment: "Button to generate image"
                        )
                    } else {
                        Text(
                            "Add to Queue",
                            comment: "Button to generate image"
                        )
                    }
                }
                .keyboardShortcut("G", modifiers: .command)
                .disabled(controller.modelName.isEmpty)
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
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(store.images.isEmpty || focusController.isTextFieldFocused)

                Button {
                    Task { await ImageController.shared.selectPrevious() }
                } label: {
                    Text(
                        "Select Previous",
                        comment: "Select previous image in Gallery"
                    )
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(store.images.isEmpty || focusController.isTextFieldFocused)
            }
            Section {
                Button {
                    guard let sdi = store.selected() else { return }
                    Task { await ImageController.shared.selectStartingImage(sdi: sdi) }
                } label: {
                    Text(
                        "Set as Starting Image",
                        comment: "Set the current image as the starting image for img2img"
                    )
                }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(store.selected() == nil)

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
                .keyboardShortcut(" ", modifiers: [])
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
                .disabled(store.selected() == nil || focusController.isTextFieldFocused)
            }
        }
    }
}
