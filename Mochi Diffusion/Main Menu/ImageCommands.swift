//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    var generationController: GenerationController
    var galleryController: GalleryController
    var configStore: ConfigStore
    var generationState: GenerationState
    var store: ImageGallery
    var quickLook: QuickLookState
    var focusController: FocusController

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                Button {
                    Task { await generationController.generate() }
                } label: {
                    if case .ready = generationState.state {
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
                .disabled(configStore.modelId == nil)
            }
            Section {
                Button {
                    Task { await galleryController.selectNext() }
                } label: {
                    Text(
                        "Select Next",
                        comment: "Select next image in Gallery"
                    )
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(store.images.isEmpty || focusController.isTextFieldFocused)

                Button {
                    Task { await galleryController.selectPrevious() }
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
                    Task { await generationController.selectStartingImage(sdi: sdi) }
                } label: {
                    Text(
                        "Set as Starting Image",
                        comment: "Set the current image as the starting image for img2img"
                    )
                }
                .keyboardShortcut("E", modifiers: .command)
                .disabled(store.selected() == nil)

                Button {
                    quickLook.toggle(image: store.selected())
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
                    Task { await galleryController.removeCurrentImage() }
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
