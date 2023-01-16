//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button {
                    guard let sdi = store.getSelectedImage else { return }
                    sdi.save()
                } label: {
                    Text("Save As...",
                         comment: "Show the save image dialog")
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(store.getSelectedImage == nil)

                Button {
                    store.saveAllImages()
                } label: {
                    Text("Save All...",
                         comment: "Show the save images dialog")
                }
                .keyboardShortcut("S", modifiers: [.command, .option])
                .disabled(store.images.count == 0)
            }
        }
    }
}
