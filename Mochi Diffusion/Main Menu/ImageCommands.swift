//
//  ImageCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/14/23.
//

import SwiftUI

struct ImageCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandMenu("Image") {
            Section {
                if case .running = store.mainViewStatus {
                    Button(action: store.stopGeneration) {
                        Text("Stop Generation")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                } else {
                    Button(action: store.generate) {
                        Text("Generate")
                    }
                    .keyboardShortcut("G", modifiers: .command)
                    .disabled(store.currentModel.isEmpty)
                }
            }
            Section {
                Button {
                    store.selectNextImage()
                } label: {
                    Text("Select Next",
                         comment: "Keyboard shortcut action to select next image in Gallery")
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.images.count == 0)

                Button {
                    store.selectPreviousImage()
                } label: {
                    Text("Select Previous",
                         comment: "Keyboard shortcut action to select previous image in Gallery")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.images.count == 0)
            }
            Section {
                Button {
                    store.upscaleCurrentImage()
                } label: {
                    Text("Convert to High Resolution",
                         comment: "Action to convert the image to high resolution")
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(store.getSelectedImage == nil)

                Button {
                    store.quicklookCurrentImage()
                } label: {
                    Text("Quick Look",
                         comment: "Keyboard shortcut action to view selected image using Quick Look")
                }
                .keyboardShortcut("L", modifiers: .command)
                .disabled(store.getSelectedImage == nil)
            }
            Section {
                Button {
                    store.removeCurrentImage()
                } label: {
                    Text("Remove",
                         comment: "Action to remove image from the gallery")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.getSelectedImage == nil)
            }
        }
    }
}
