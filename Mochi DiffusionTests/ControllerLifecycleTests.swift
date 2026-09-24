//
//  ControllerLifecycleTests.swift
//  Mochi DiffusionTests
//

import AppKit
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins that a controller can actually be released.
///
/// A monitor loop iterates a stream that never ends, so a strong `self` hoisted
/// out of the loop would make the task and the controller keep each other alive.
@MainActor
struct ControllerLifecycleTests {
    @Test("A generation controller is released after shutdown")
    func generationControllerIsReleased() async {
        let defaults = TempDefaults()
        weak var weakController: GenerationController?

        do {
            let controller = makeTestGenerationController(
                configStore: ConfigStore(store: defaults.defaults),
                startsObserving: true
            )
            weakController = controller
            #expect(weakController != nil)
            controller.shutdown()
        }

        // Cancelled tasks have to unwind before they stop referencing anything.
        await Task.yield()
        #expect(weakController == nil)
    }

    @Test("A gallery controller is released after shutdown")
    func galleryControllerIsReleased() async {
        let defaults = TempDefaults()
        weak var weakController: GalleryController?

        do {
            let controller = GalleryController(
                configStore: ConfigStore(store: defaults.defaults),
                imageGallery: ImageGallery()
            )
            weakController = controller
            #expect(weakController != nil)
            controller.shutdown()
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    /// `withObservationTracking` callbacks stay armed until they fire, and firing
    /// re-registers them, so cancelling tasks alone would not stop a settings
    /// change after `shutdown()` from scheduling work that holds the controller.
    @Test("A settings change after shutdown does not revive the controller")
    func settingsChangeAfterShutdownDoesNothing() async {
        let defaults = TempDefaults()
        let configStore = ConfigStore(store: defaults.defaults)
        weak var weakController: GenerationController?

        do {
            let controller = makeTestGenerationController(
                configStore: configStore, startsObserving: true)
            weakController = controller
            controller.shutdown()
            configStore.modelDir = "/tmp/mochi-somewhere-else"
            configStore.controlNetDir = "/tmp/mochi-controlnet-elsewhere"
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    @Test("A settings change after gallery shutdown does not revive it")
    func gallerySettingsChangeAfterShutdownDoesNothing() async {
        let defaults = TempDefaults()
        let configStore = ConfigStore(store: defaults.defaults)
        weak var weakController: GalleryController?

        do {
            let controller = GalleryController(
                configStore: configStore,
                imageGallery: ImageGallery()
            )
            weakController = controller
            controller.shutdown()
            configStore.imageDir = "/tmp/mochi-images-elsewhere"
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    @Test("Shutting down twice is harmless")
    func shutdownIsIdempotent() {
        let defaults = TempDefaults()
        let controller = makeTestGenerationController(
            configStore: ConfigStore(store: defaults.defaults),
            startsObserving: true
        )

        controller.shutdown()
        controller.shutdown()
    }
}

@MainActor
struct ModalPresentationTests {
    private func window() -> NSWindow {
        NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test("The main window is the preferred sheet presenter")
    func prefersMainWindow() {
        let main = window()
        let key = window()

        guard
            case .sheet(let presenter) = ModalPresentation.mode(
                mainWindow: main,
                keyWindow: key,
                orderedWindows: []
            )
        else {
            Issue.record("Expected sheet presentation")
            return
        }
        #expect(presenter === main)
    }

    @Test("A usable key window presents the sheet when there is no main window")
    func usesKeyWindowFallback() {
        let key = window()

        guard
            case .sheet(let presenter) = ModalPresentation.mode(
                mainWindow: nil,
                keyWindow: key,
                orderedWindows: []
            )
        else {
            Issue.record("Expected sheet presentation")
            return
        }
        #expect(presenter === key)
    }

    @Test("An ordered app window presents the sheet when main and key are absent")
    func usesOrderedWindowFallback() {
        let ordered = window()

        guard
            case .sheet(let presenter) = ModalPresentation.mode(
                mainWindow: nil,
                keyWindow: nil,
                orderedWindows: [ordered]
            )
        else {
            Issue.record("Expected sheet presentation")
            return
        }
        #expect(presenter === ordered)
    }

    @Test("No presenter uses application-modal fallback")
    func usesApplicationModalFallback() {
        guard
            case .applicationModal = ModalPresentation.mode(
                mainWindow: nil,
                keyWindow: nil,
                orderedWindows: []
            )
        else {
            Issue.record("Expected application-modal presentation")
            return
        }
    }
}

struct SettingsDirectoryTests {
    @Test(
        "Stored directory paths become file URLs without changing their text",
        arguments: [
            SettingsDirectory.images,
            SettingsDirectory.models,
            SettingsDirectory.controlNet,
        ]
    )
    func storedPathBecomesFileURL(directory: SettingsDirectory) {
        let path = "/Volumes/External Drive/モデル/Control Net"

        let url = directory.url(fromPath: path)

        #expect(url.isFileURL)
        #expect(url.hasDirectoryPath)
        #expect(url.pathComponents == URL(fileURLWithPath: path).pathComponents)
    }

    @Test("Empty settings open each repository's default directory")
    func emptyPathUsesRepositoryDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser

        #expect(
            SettingsDirectory.images.url(fromPath: "")
                == home.appending(path: "MochiDiffusion/images", directoryHint: .isDirectory)
        )
        #expect(
            SettingsDirectory.models.url(fromPath: "")
                == home.appending(path: "MochiDiffusion/models", directoryHint: .isDirectory)
        )
        #expect(
            SettingsDirectory.controlNet.url(fromPath: "")
                == home.appending(path: "MochiDiffusion/controlnet", directoryHint: .isDirectory)
        )
    }
}
