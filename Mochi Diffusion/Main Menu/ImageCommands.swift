//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    @ObservedObject var controller: ImageController
    @ObservedObject var store: ImageStore

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                if case .running = ImageGenerator.shared.state {
                    Button {
                        Task { await ImageGenerator.shared.stopGenerate() }
                    } label: {
                        Text("Stop Generation")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                } else {
                    Button {
                        Task { await controller.generate() }
                    } label: {
                        Text("Generate")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                    .disabled(controller.modelName.isEmpty)
                }
            }
            Section {
                Button {
                    Task { await controller.selectNext() }
                } label: {
                    Text(
                        "Select Next",
                        comment: "Select next image in Gallery"
                    )
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.images.isEmpty)

                Button {
                    Task { await controller.selectPrevious() }
                } label: {
                    Text(
                        "Select Previous",
                        comment: "Select previous image in Gallery"
                    )
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.images.isEmpty)
            }
            Section {
                Button {
                    Task { await controller.upscaleCurrentImage() }
                } label: {
                    Text(
                        "Convert to High Resolution",
                        comment: "Convert the current image to high resolution"
                    )
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(controller.selectedImage == nil)

                Button {
                    fatalError()
                } label: {
                    Text(
                        "Quick Look",
                        comment: "View current image using Quick Look"
                    )
                }
                .keyboardShortcut("L", modifiers: .command)
                .disabled(controller.selectedImage == nil)
            }
            Section {
                Button {
                    Task { await controller.removeCurrentImage() }
                } label: {
                    Text(
                        "Remove",
                        comment: "Remove image from the gallery"
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(controller.selectedImage == nil)
            }
        }
    }
}
