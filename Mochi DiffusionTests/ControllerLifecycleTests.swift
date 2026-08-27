//
//  ControllerLifecycleTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins that a controller can actually be released.
///
/// Phase 3 fixed loops that hoisted a strong `self` before entering a stream that
/// never ends, so task and controller kept each other alive. Nothing catches a
/// regression of that except a test like this one: re-hoisting a `guard let self`
/// out of a loop compiles, reads as a simplification, and silently restores the
/// cycle.
@MainActor
struct ControllerLifecycleTests {
    @Test("A generation controller is released after shutdown")
    func generationControllerIsReleased() async throws {
        let defaults = try TempDefaults()
        weak var weakController: GenerationController?

        do {
            let controller = GenerationController(
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
    func galleryControllerIsReleased() async throws {
        let defaults = try TempDefaults()
        weak var weakController: GalleryController?

        do {
            let controller = GalleryController(
                configStore: ConfigStore(store: defaults.defaults),
                focusController: FocusController()
            )
            weakController = controller
            #expect(weakController != nil)
            controller.shutdown()
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    /// `withObservationTracking` callbacks stay armed until they fire, and firing
    /// is what re-registers them — so cancelling tasks did not stop a settings
    /// change after `shutdown()` from arming observation and scheduling debounce
    /// work all over again. If it still did, the new task would hold the
    /// controller and this would not deallocate.
    @Test("A settings change after shutdown does not revive the controller")
    func settingsChangeAfterShutdownDoesNothing() async throws {
        let defaults = try TempDefaults()
        let configStore = ConfigStore(store: defaults.defaults)
        weak var weakController: GenerationController?

        do {
            let controller = GenerationController(configStore: configStore, startsObserving: true)
            weakController = controller
            controller.shutdown()
            configStore.modelDir = "/tmp/mochi-somewhere-else"
            configStore.controlNetDir = "/tmp/mochi-controlnet-elsewhere"
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    @Test("A settings change after gallery shutdown does not revive it")
    func gallerySettingsChangeAfterShutdownDoesNothing() async throws {
        let defaults = try TempDefaults()
        let configStore = ConfigStore(store: defaults.defaults)
        weak var weakController: GalleryController?

        do {
            let controller = GalleryController(
                configStore: configStore,
                focusController: FocusController()
            )
            weakController = controller
            controller.shutdown()
            configStore.imageDir = "/tmp/mochi-images-elsewhere"
        }

        await Task.yield()
        #expect(weakController == nil)
    }

    @Test("Shutting down twice is harmless")
    func shutdownIsIdempotent() throws {
        let defaults = try TempDefaults()
        let controller = GenerationController(
            configStore: ConfigStore(store: defaults.defaults),
            startsObserving: true
        )

        controller.shutdown()
        controller.shutdown()
    }
}
