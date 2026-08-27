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
