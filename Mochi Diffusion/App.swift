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
    @StateObject private var controller: ImageController
    @StateObject private var generator: ImageGenerator
    @StateObject private var store: ImageStore
    private let updaterController: SPUStandardUpdaterController

    init() {
        self._controller = .init(wrappedValue: .shared)
        self._generator = .init(wrappedValue: .shared)
        self._store = .init(wrappedValue: .shared)

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            AppView()
                .environmentObject(controller)
                .environmentObject(generator)
                .environmentObject(store)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    // cleanup quick look temp images
                    NSImage.cleanupTempFiles()
                    // cleanup MPS temp folder
                    let mpsURL = FileManager.default.temporaryDirectory.appendingPathComponent("com.apple.MetalPerformanceShadersGraph", isDirectory: true)
                    try? FileManager.default.removeItem(at: mpsURL)
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: CommandGroupPlacement.newItem) { /* hide new window */ }
            FileCommands(store: store)
            SidebarCommands()
            ImageCommands(controller: controller, generator: generator, store: store)
            HelpCommands()
        }
        .defaultSize(width: 1_120, height: 670)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}
