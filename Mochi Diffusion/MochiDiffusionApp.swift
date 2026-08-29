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
    @State private var configStore: ConfigStore
    @State private var generationController: GenerationController
    @State private var galleryController: GalleryController
    @State private var generationState: GenerationState
    @State private var store: ImageGallery
    @State private var focusCon: FocusController
    @State private var notificationController: NotificationController
    @State private var quickLook: QuickLookState
    @State private var quicklookURL: URL?
    /// Owned here so the thumbnail cache lives as long as the app rather than as long
    /// as whichever view happened to ask first.
    private let thumbnailProvider = GalleryThumbnailProvider()
    private let fullImageProvider = GalleryFullImageProvider()
    private let updaterController: SPUStandardUpdaterController

    init() {
        let configStore = ConfigStore()
        let focusController = FocusController()
        // The app owns the one gallery and the one queue, and hands them to
        // everything that needs them. Neither has a `.shared`, so there is no way
        // for code elsewhere to reach a different one by accident.
        let imageGallery = ImageGallery()
        // The one place the real credential store is wired in. The registry
        // initialiser default is keychain-free, so a test that does not pass one
        // cannot reach the user's keychain.
        let generationService = GenerationService(
            engineRegistry: EngineRegistry(secrets: KeychainSecretStore()),
            imageGallery: imageGallery
        )
        self._configStore = State(initialValue: configStore)
        self._generationController = State(
            initialValue: GenerationController(
                configStore: configStore,
                imageGallery: imageGallery,
                generationService: generationService,
                engineRegistry: EngineRegistry(secrets: KeychainSecretStore())
            )
        )
        self._galleryController = State(
            initialValue: GalleryController(
                configStore: configStore,
                imageGallery: imageGallery,
                focusController: focusController
            )
        )
        self._generationState = .init(wrappedValue: .shared)
        self._store = .init(wrappedValue: imageGallery)
        self._focusCon = .init(wrappedValue: focusController)
        self._notificationController = .init(wrappedValue: .shared)
        self._quickLook = State(initialValue: QuickLookState())

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        Window("Mochi Diffusion", id: "main") {
            AppView()
                .sheet(isPresented: $galleryController.isLoading) {
                    VStack {
                        ProgressView()
                        Spacer().frame(height: 16)
                        Text("Loading...")
                    }
                    .padding([.top, .bottom], 40)
                    .padding([.leading, .trailing], 60)
                }
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
                .onChange(of: quickLook.url) { _, newValue in
                    if quicklookURL != newValue { quicklookURL = newValue }
                }
                .onChange(of: quicklookURL) { _, newValue in
                    if newValue == nil { quickLook.close() }
                }
                .quickLookPreview($quicklookURL)
        }
        .environment(configStore)
        .environment(generationController)
        .environment(galleryController)
        .environment(generationState)
        .environment(store)
        .environment(focusCon)
        .environment(quickLook)
        .environment(\.galleryThumbnailProvider, thumbnailProvider)
        .environment(\.galleryFullImageProvider, fullImageProvider)
        .commands {
            AppCommands(updater: updaterController.updater)
            FileCommands(galleryController: galleryController, store: store)
            SidebarCommands()
            ImageCommands(
                generationController: generationController,
                galleryController: galleryController,
                configStore: configStore,
                generationState: generationState,
                store: store,
                quickLook: quickLook,
                focusController: focusCon
            )
            HelpCommands()
        }
        .defaultSize(width: 1_120, height: 670)

        Settings {
            SettingsView()
                .environment(notificationController)
        }
        .environment(configStore)
        .environment(generationController)
    }
}
