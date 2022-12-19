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
                Button("Save Image...") {
                    guard let sdi = store.selectedImage else { return }
                    sdi.save()
                }
                .keyboardShortcut("S", modifiers: .command)
                .disabled(store.selectedImage == nil)
            }
        }
    }
}
