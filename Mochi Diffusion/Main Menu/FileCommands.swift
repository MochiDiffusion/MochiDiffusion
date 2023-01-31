//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var genStore: GeneratorStore

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button {
                    guard let sdi = genStore.getSelectedImage else { return }
                    sdi.save()
                } label: {
                    Text(
                        "Save As...",
                        comment: "Show the save image dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(genStore.getSelectedImage == nil)

                Button {
                    genStore.saveAllImages()
                } label: {
                    Text(
                        "Save All...",
                        comment: "Show the save images dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: [.command, .option])
                .disabled(genStore.images.isEmpty)
            }
        }
        CommandGroup(replacing: .importExport) {
            Section {
                Button {
                    genStore.importImages()
                } label: {
                    Text(
                        "Import Image...",
                        comment: "Show the import image dialog"
                    )
                }
                .keyboardShortcut("I", modifiers: .command)
            }
        }
    }
}
