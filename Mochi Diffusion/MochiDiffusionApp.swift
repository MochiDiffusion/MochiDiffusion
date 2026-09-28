//
//  MochiDiffusionApp.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/16/22.
//

import QuickLook
import Sparkle
import SwiftUI

@main
struct MochiDiffusionApp: App {
    @State private var configStore: ConfigStore
    @State private var generationController: GenerationController
    @State private var galleryController: GalleryController
    @State private var generationState: GenerationState
    @State private var store: ImageGallery
    @State private var notificationController: NotificationController
    @State private var quickLook: QuickLookState
    /// Mirrors `quickLook.url` for `quickLookPreview`, which reads its binding off the
    /// main thread. A `Binding(get:set:)` over the main-actor `QuickLookState` would
    /// trap on that read under Swift 6 isolation checking; a `@State` binding does not.
    @State private var quickLookURL: URL?

    private let thumbnailProvider: GalleryThumbnailProvider
    private let fullImageProvider: GalleryFullImageProvider
    private let updaterController: SPUStandardUpdaterController

    init() {
        let configStore = ConfigStore()
        // One repository for every writer, so filename allocation covers all of
        // them. See `ImageRepository`.
        let imageRepository = ImageRepository()
        let imageGallery = ImageGallery()
        let thumbnailProvider = GalleryThumbnailProvider()
        let fullImageProvider = GalleryFullImageProvider()
        let engineRegistry = EngineRegistry()
        self.thumbnailProvider = thumbnailProvider
        self.fullImageProvider = fullImageProvider
        let generationService = GenerationService(
            imageRepository: imageRepository,
            engineRegistry: engineRegistry,
            imageGallery: imageGallery
        )
        self._configStore = State(initialValue: configStore)
        self._generationController = State(
            initialValue: GenerationController(
                configStore: configStore,
                imageRepository: imageRepository,
                imageGallery: imageGallery,
                generationService: generationService,
                engineRegistry: engineRegistry,
                fullImageProvider: fullImageProvider
            )
        )
        self._galleryController = State(
            initialValue: GalleryController(
                configStore: configStore,
                imageGallery: imageGallery,
                imageRepository: imageRepository,
                // The same instances the views read from, so invalidating on a
                // delete or an import reaches what is actually on screen.
                thumbnailProvider: thumbnailProvider,
                fullImageProvider: fullImageProvider
            )
        )
        self._generationState = .init(wrappedValue: .shared)
        self._store = .init(wrappedValue: imageGallery)
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
                    // Clean up Quick Look temporary images and the MPS temporary folder.
                    NSImage.cleanupTempFiles()
                    let mpsURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "com.apple.MetalPerformanceShadersGraph", isDirectory: true)
                    try? FileManager.default.removeItem(at: mpsURL)
                }
                .onChange(of: quickLook.url) { _, newValue in
                    if quickLookURL != newValue { quickLookURL = newValue }
                }
                // The preview reports dismissal by clearing the URL.
                .onChange(of: quickLookURL) { _, newValue in
                    if newValue == nil { quickLook.close() }
                }
                .quickLookPreview($quickLookURL)
        }
        .environment(configStore)
        .environment(generationController)
        .environment(galleryController)
        .environment(generationState)
        .environment(store)
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
                store: store
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
