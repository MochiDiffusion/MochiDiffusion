//
//  MochiDiffusionApp.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import QuickLook
import Sparkle
import SwiftUI
import UserNotifications

@main
struct MochiDiffusionApp: App {
    @StateObject private var controller: ImageController
    @State private var generator: ImageGenerator
    @State private var store: ImageStore
    @State private var focusCon: FocusController
    @State private var notificationController: NotificationController
    private let updaterController: SPUStandardUpdaterController

    init() {
        self._controller = .init(wrappedValue: .shared)
        self._generator = .init(wrappedValue: .shared)
        self._store = .init(wrappedValue: .shared)
        self._focusCon = .init(wrappedValue: .shared)
        self._notificationController = .init(wrappedValue: .shared)

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        Window("Mochi Diffusion", id: "main") {
            AppView()
                .environmentObject(controller)
                .environment(generator)
                .environment(store)
                .environment(focusCon)
                .sheet(isPresented: $controller.isLoading) {
                    VStack {
                        ProgressView()
                        Spacer().frame(height: 16)
                        Text("Loading...")
                    }
                    .padding([.top, .bottom], 40)
                    .padding([.leading, .trailing], 60)
                }
                .quickLookPreview($controller.quicklookURL)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSApplication.willTerminateNotification)
                ) { _ in
                    /// cleanup quick look temp images
                    NSImage.cleanupTempFiles()
                    /// cleanup MPS temp folder
                    let mpsURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "com.apple.MetalPerformanceShadersGraph", isDirectory: true)
                    try? FileManager.default.removeItem(at: mpsURL)
                }
        }
        .commands {
            AppCommands(updater: updaterController.updater)
            FileCommands(store: store)
            SidebarCommands()
            ImageCommands(
                controller: controller, generator: generator, store: store,
                focusController: focusCon)
            HelpCommands()
        }
        .defaultSize(width: 1_120, height: 670)

        Settings {
            SettingsView()
                .environmentObject(controller)
                .environment(notificationController)
        }
    }
}
