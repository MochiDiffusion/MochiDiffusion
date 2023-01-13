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
                         comment: "File menu option to show the save image dialog")
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(store.getSelectedImage == nil)
            }
            Section {
                Button(action: store.generate) {
                    Text("Generate")
                }
                .keyboardShortcut("G", modifiers: .command)
                .disabled(store.currentModel.isEmpty)
            }
        }
    }
}
