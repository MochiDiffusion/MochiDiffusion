//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    var store: ImageStore

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button {
                    Task {
                        guard let sdi = store.selected() else { return }
                        await sdi.saveAs()
                    }
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

            if let sdi = store.selected() {
                Section {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: sdi.path).absoluteURL
                        ])
                    } label: {
                        Text(
                            "Show in Finder",
                            comment: "Show image with Finder"
                        )
                    }
                    .disabled(sdi.path.isEmpty)
                }
            }
        }
        CommandGroup(replacing: .importExport) {
            Section {
                Button {
                    Task { await ImageController.shared.importImages() }
                } label: {
                    Text(
                        "Import Images...",
                        comment: "Show the import image dialog"
                    )
                }
                .keyboardShortcut("I", modifiers: .command)
            }
        }
    }
}
