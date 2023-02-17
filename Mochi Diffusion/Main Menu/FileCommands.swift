//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var store: ImageStore

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button {
                    guard let sdi = store.selected() else { return }
                    sdi.save()
                } label: {
                    Text(
                        "Save As...",
                        comment: "Show the save image dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(store.selected() == nil)

                Button {
                    Task { await ImageController.shared.saveAll() }
                } label: {
                    Text(
                        "Save All...",
                        comment: "Show the save images dialog"
                    )
                }
                .keyboardShortcut("S", modifiers: [.command, .option])
                .disabled(store.images.isEmpty)
            }
        }
        CommandGroup(replacing: .importExport) {
            Section {
                Button {
                    Task { await ImageController.shared.importImages() }
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
