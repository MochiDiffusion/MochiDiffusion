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

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                Button {
                    Task { await generationController.generate() }
                } label: {
                    if !generationController.hasGenerationWork {
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
                .disabled(generationController.currentModelId == nil)
            }
            Section {
                Button {
                    guard let sdi = store.selected() else { return }
                    Task { await generationController.useGalleryImage(sdi) }
                } label: {
                    switch generationController.galleryImageDestination {
                    case .inputImage:
                        Text(
                            "Set as Input Image",
                            comment: "Use the selected gallery image as a model reference input"
                        )
                    case .startingImage, .none:
                        Text(
                            "Set as Starting Image",
                            comment: "Set the current image as the starting image for img2img"
                        )
                    }
                }
                .keyboardShortcut("E", modifiers: .command)
                .disabled(
                    store.selected() == nil
                        || generationController.galleryImageDestination == nil
                )
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
                .disabled(store.selected() == nil)
            }
        }
    }
}
