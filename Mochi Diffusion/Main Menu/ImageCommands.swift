//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    @ObservedObject var genStore: GeneratorStore

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                if case .running = genStore.status {
                    Button {
                        genStore.stopGeneration()
                    } label: {
                        Text("Stop Generation")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                } else {
                    Button {
                        genStore.generate()
                    } label: {
                        Text("Generate")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                    .disabled(genStore.currentModel.isEmpty)
                }
            }
            Section {
                Button {
                    genStore.selectNextImage()
                } label: {
                    Text(
                        "Select Next",
                        comment: "Select next image in Gallery"
                    )
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(genStore.images.isEmpty)

                Button {
                    genStore.selectPreviousImage()
                } label: {
                    Text(
                        "Select Previous",
                        comment: "Select previous image in Gallery"
                    )
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(genStore.images.isEmpty)
            }
            Section {
                Button {
                    genStore.upscaleCurrentImage()
                } label: {
                    Text(
                        "Convert to High Resolution",
                        comment: "Convert the current image to high resolution"
                    )
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(genStore.getSelectedImage == nil)

                Button {
                    genStore.quicklookCurrentImage()
                } label: {
                    Text(
                        "Quick Look",
                        comment: "View current image using Quick Look"
                    )
                }
                .keyboardShortcut("L", modifiers: .command)
                .disabled(genStore.getSelectedImage == nil)
            }
            Section {
                Button {
                    genStore.removeCurrentImage()
                } label: {
                    Text(
                        "Remove",
                        comment: "Remove image from the gallery"
                    )
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(genStore.getSelectedImage == nil)
            }
        }
    }
}
