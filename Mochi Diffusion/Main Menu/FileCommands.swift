//
//  SaveCommands.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

struct FileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Section {
                Button("Save Image...") {
                    
                }
                .keyboardShortcut("S", modifiers: .command)
            }
            Section {
                Button("Get Info") {
                    
                }
                .keyboardShortcut("I", modifiers: .command)
            }
        }
    }
}
