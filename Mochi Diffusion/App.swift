//
//  App.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import Sparkle
import SwiftUI

// This view model class publishes when new updates can be checked by the user
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

// This is the view for the Check for Updates menu item
// Note this intermediate view is necessary for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more info
struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }

    init(updater: SPUUpdater) {
        self.updater = updater

        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
}

@main
struct MochiDiffusionApp: App {
    @StateObject private var genStore = GeneratorStore()
//    @StateObject private var imageStore = ImageStore([])
//    @StateObject private var galleryStore = GalleryStore()
//    @State private var selectedId: SDImage.ID?
    private let updaterController: SPUStandardUpdaterController

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(genStore)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: CommandGroupPlacement.newItem) { /* hide new window */ }
            FileCommands(genStore: genStore)
            SidebarCommands()
            ImageCommands(genStore: genStore)
            HelpCommands()
        }
        .defaultSize(width: 1_120, height: 670)

        Settings {
            SettingsView()
                .environmentObject(genStore)
        }
    }

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
