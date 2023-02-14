//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var controller: ImageController

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button {
                    guard let sdi = controller.selectedImage else { return }
                    sdi.save()
                } label: {
                    Text(
                        "Save As...",
                        comment: "Show the save image dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(controller.selectedImage == nil)

                Button {
                    Task { await controller.saveAll() }
                } label: {
                    Text(
                        "Save All...",
                        comment: "Show the save images dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: [.command, .option])
                .disabled(controller.store.images.isEmpty)
            }
        }
        CommandGroup(replacing: .importExport) {
            Section {
                Button {
                    controller.importImages()
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
