//
//  App.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import SwiftUI

@main
struct MochiDiffusionApp: App {
    var body: some Scene {
        WindowGroup {
            LoadingView()
        }
        .commands{
            HelpCommands()
//            SaveCommands()
            SidebarCommands()
            TextEditingCommands()
        }
    }
}

extension String: Error {}
