//
//  GenerationOwnershipTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins that the in-progress preview belongs to one request at a time.
///
/// Results and progress events travel on separate channels — results need
/// back-pressure, previews do not — so nothing orders a result against the next
/// request's first preview. Clearing the preview used to be unconditional, so a
/// result applied late erased a preview belonging to a generation still running.
///
/// `.serialized` because `ImageGallery` is a main-actor singleton.
@MainActor
@Suite(.serialized)
struct PreviewOwnershipTests {
    private let first = UUID()
    private let second = UUID()

    init() {
        ImageGallery.shared.clearCurrentGenerating()
    }

    @Test("A preview is shown and cleared by its owner")
    func ownerClearsItsOwnPreview() {
        let image = makeCGImage()
        ImageGallery.shared.setCurrentGenerating(image: image, owner: first)
        #expect(ImageGallery.shared.currentGeneratingImage != nil)

        ImageGallery.shared.clearCurrentGenerating(owner: first)

        #expect(ImageGallery.shared.currentGeneratingImage == nil)
    }

    /// The defect. A finished request's teardown must not erase the preview of the
    /// one that has already started.
    @Test("A clear from another request leaves the preview alone")
    func clearFromAnotherRequestIsIgnored() {
        ImageGallery.shared.setCurrentGenerating(image: makeCGImage(), owner: second)

        ImageGallery.shared.clearCurrentGenerating(owner: first)

        #expect(ImageGallery.shared.currentGeneratingImage != nil)
    }

    /// The full ordering the bug needed: the next request takes the slot, and only
    /// then does the previous request's result get applied.
    @Test("A late result cannot erase the next request's preview")
    func lateResultDoesNotEraseNextPreview() {
        ImageGallery.shared.setCurrentGenerating(image: makeCGImage(), owner: first)
        ImageGallery.shared.setCurrentGenerating(image: makeCGImage(), owner: second)

        // `first`'s result is applied now, after `second` has taken the slot.
        ImageGallery.shared.clearCurrentGenerating(owner: first)

        #expect(ImageGallery.shared.currentGeneratingImage != nil)

        ImageGallery.shared.clearCurrentGenerating(owner: second)

        #expect(ImageGallery.shared.currentGeneratingImage == nil)
    }

    /// Teardown that is ending generation altogether, rather than finishing one
    /// request, still clears whatever is there.
    @Test("An unscoped clear takes the preview whoever owns it")
    func unscopedClearAlwaysClears() {
        ImageGallery.shared.setCurrentGenerating(image: makeCGImage(), owner: second)

        ImageGallery.shared.clearCurrentGenerating()

        #expect(ImageGallery.shared.currentGeneratingImage == nil)
    }

    @Test("Clearing an unowned preview is harmless")
    func clearingWhenNothingIsShownIsHarmless() {
        ImageGallery.shared.clearCurrentGenerating(owner: first)

        #expect(ImageGallery.shared.currentGeneratingImage == nil)
    }
}

/// Pins that a request cancelled while queued does not pay for a model load.
///
/// Waiting for the Iris lease is unbounded — it lasts as long as the generation
/// ahead of it — so a request cancelled during that wait used to take its turn and
/// run `iris_metal_init` and `iris_load_dir` before reaching the first cancellation
/// check, holding the process-global lease against work that was still wanted.
struct IrisCancelledWaiterTests {
    private func makeRequest() -> GenerationRequest {
        GenerationRequest(
            modelID: ModelID(engine: .iris, key: "klein"),
            displayName: "klein",
            metadataFields: [.prompt],
            payload: IrisGenerationPayload(
                modelDirectory: "/nonexistent",
                stepCount: 4,
                scheduler: .discreteFlowScheduler
            ),
            prompt: "a cat",
            negativePrompt: "",
            size: CGSize(width: 64, height: 64),
            startingImageData: nil,
            startingImageName: nil,
            controlNetImageData: [],
            controlNetNames: [],
            controlNetImageNames: [],
            inputImageNames: [],
            strength: 0.75,
            stepCount: 4,
            guidanceScale: nil,
            scheduler: .discreteFlowScheduler,
            mlComputeUnit: nil,
            useDenoisedIntermediates: false,
            seed: 1,
            numberOfImages: 1,
            imageDir: FileManager.default.temporaryDirectory.path(percentEncoded: false),
            imageType: "png"
        )
    }

    /// Returning at all is most of the point: the model directory does not exist,
    /// so reaching `iris_load_dir` would fail rather than return cleanly.
    @Test("A request cancelled before it gets the lease loads nothing")
    func cancelledRequestSkipsSetup() async throws {
        let request = makeRequest()
        let session = GenerationSession(requestID: request.id)
        session.cancel()

        try await IrisEngineRuntime().run(
            request: request,
            session: session,
            onResult: { _ in Issue.record("a cancelled request produced a result") }
        )
    }

    @Test("A cancelled request hands the lease back")
    func cancelledRequestReleasesTheLease() async throws {
        let request = makeRequest()
        let session = GenerationSession(requestID: request.id)
        session.cancel()

        try await IrisEngineRuntime().run(
            request: request,
            session: session,
            onResult: { _ in }
        )

        #expect(await IrisSingleFlight.shared.isCurrentlyHeld == false)
    }
}
