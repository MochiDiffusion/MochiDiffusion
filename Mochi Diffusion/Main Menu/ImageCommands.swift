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
                         comment: "Select next image in Gallery")
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(store.images.count == 0)

                Button {
                    store.selectPreviousImage()
                } label: {
                    Text("Select Previous",
                         comment: "Select previous image in Gallery")
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(store.images.count == 0)
            }
            Section {
                Button {
                    store.upscaleCurrentImage()
                } label: {
                    Text("Convert to High Resolution",
                         comment: "Convert the current image to high resolution")
                }
                .keyboardShortcut("R", modifiers: .command)
                .disabled(store.getSelectedImage == nil)

                Button {
                    store.quicklookCurrentImage()
                } label: {
                    Text("Quick Look",
                         comment: "View current image using Quick Look")
                }
                .keyboardShortcut("L", modifiers: .command)
                .disabled(store.getSelectedImage == nil)
            }
            Section {
                Button {
                    store.removeCurrentImage()
                } label: {
                    Text("Remove",
                         comment: "Remove image from the gallery")
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(store.getSelectedImage == nil)
            }
        }
    }
}
