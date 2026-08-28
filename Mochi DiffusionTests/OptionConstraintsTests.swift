//
//  OptionConstraintsTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins normalization: values out of range are clamped and snapped, not rejected.
///
/// The sidebar's persisted values routinely will not fit a newly selected model —
/// a width from a freeform model, a guidance scale from a Core ML one — and
/// overriding them is correct rather than an error. Rejecting would turn every
/// model switch into an error banner.
struct OptionConstraintsTests {

    // MARK: - Whole numbers

    @Test("An unsupported option resolves to nothing")
    func unsupportedIntResolvesToNil() {
        #expect(IntConstraint.unsupported.resolved(12) == nil)
        #expect(!IntConstraint.unsupported.isSupported)
        #expect(!IntConstraint.unsupported.isEditable)
    }

    /// The case that made the old capability flags insufficient: the sidebar
    /// offered an editable step count, the generator used four, and the saved
    /// metadata then disagreed with what was on screen.
    @Test("A pinned option ignores what was requested", arguments: [1, 4, 20, 999])
    func pinnedIntIgnoresRequest(requested: Int) {
        #expect(IntConstraint.pinned(4).resolved(requested) == 4)
        #expect(IntConstraint.pinned(4).isSupported)
        #expect(!IntConstraint.pinned(4).isEditable)
    }

    @Test(
        "A ranged option clamps rather than rejecting",
        arguments: [(0, 1), (1, 1), (25, 25), (50, 50), (51, 50), (10_000, 50)]
    )
    func rangedIntClamps(requested: Int, expected: Int) {
        #expect(IntConstraint.range(1...50, step: 1).resolved(requested) == expected)
    }

    @Test(
        "A ranged option snaps to its step",
        arguments: [(64, 64), (70, 64), (72, 80), (76, 80), (1_790, 1_792)]
    )
    func rangedIntSnaps(requested: Int, expected: Int) {
        #expect(IntConstraint.range(64...1_792, step: 16).resolved(requested) == expected)
    }

    /// The released step and image-count sliders pass `strictUpperBound: false`,
    /// so a typed value above the span is kept. A constraint that clamped to the
    /// span would show 75 steps and generate 50.
    @Test(
        "A value above the span is kept when the control allows it",
        arguments: [(51, 51), (75, 75), (1_000, 1_000), (0, 1)]
    )
    func softUpperBoundIsHonoured(requested: Int, expected: Int) {
        let soft = IntConstraint.range(1...50, step: 1, acceptsBeyondUpperBound: true)

        #expect(soft.resolved(requested) == expected)
        #expect(soft.allowsValuesAboveBounds)
        // The control still spans the suggested range.
        #expect(soft.bounds == 1...50)
    }

    @Test("A value above the span is clamped when the control does not allow it")
    func hardUpperBoundClamps() {
        let hard = IntConstraint.range(1...50, step: 1)

        #expect(hard.resolved(75) == 50)
        #expect(!hard.allowsValuesAboveBounds)
    }

    @Test("Snapping respects a soft upper bound")
    func snappingRespectsSoftBound() {
        let soft = IntConstraint.range(64...128, step: 16, acceptsBeyondUpperBound: true)

        #expect(soft.resolved(200) == 208)
        #expect(soft.resolved(10) == 64)
    }

    @Test("Snapping never leaves the range")
    func snappingStaysInRange() {
        // A step that does not divide the span evenly must not snap past the top.
        let constraint = IntConstraint.range(0...10, step: 4)
        for requested in -5...15 {
            let resolved = try! #require(constraint.resolved(requested))
            #expect((0...10).contains(resolved))
        }
    }

    // MARK: - Fractions

    @Test("A fractional option clamps")
    func doubleClamps() {
        let guidance = DoubleConstraint.range(1...20, step: nil)

        #expect(guidance.resolved(0) == 1)
        #expect(guidance.resolved(100) == 20)
        // Not snapped: a constraint says what the model accepts, and Core ML
        // accepts any guidance scale. `MochiSlider` owns granularity, and
        // snapping here would move a number the user typed for no reason.
        #expect(guidance.resolved(7.4) == 7.4)
    }

    @Test("A fractional option snaps only when asked to")
    func doubleSnapsWhenStepped() {
        let stepped = DoubleConstraint.range(1...20, step: 0.5)

        #expect(stepped.resolved(7.4) == 7.5)
        #expect(stepped.resolved(7.1) == 7.0)
    }

    @Test("An unsupported fraction resolves to nothing")
    func unsupportedDoubleResolvesToNil() {
        #expect(DoubleConstraint.unsupported.resolved(0.5) == nil)
    }

    // MARK: - Size

    /// A converted Core ML model produces the resolution it was converted at,
    /// whatever the sidebar has been left set to.
    @Test("A pinned size overrides whatever was requested")
    func pinnedSizeOverrides() {
        let fixed = SizeConstraint.pinned([CGSize(width: 512, height: 768)])

        #expect(
            fixed.resolved(CGSize(width: 1_024, height: 1_024)) == CGSize(width: 512, height: 768))
        #expect(fixed.resolved(CGSize(width: 512, height: 768)) == CGSize(width: 512, height: 768))
        #expect(!fixed.isEditable)
    }

    @Test("A model offering several sizes keeps a requested one")
    func pinnedSizeKeepsOffered() {
        let sizes = [CGSize(width: 512, height: 768), CGSize(width: 768, height: 512)]
        let constraint = SizeConstraint.pinned(sizes)

        #expect(constraint.resolved(sizes[1]) == sizes[1])
    }

    @Test("A freeform size clamps and snaps both dimensions independently")
    func freeformSizeNormalizes() {
        let constraint = SizeConstraint.freeform(range: 64...1_792, step: 16)

        #expect(
            constraint.resolved(CGSize(width: 10, height: 5_000))
                == CGSize(width: 64, height: 1_792))
        #expect(constraint.resolved(CGSize(width: 70, height: 72)) == CGSize(width: 64, height: 80))
        #expect(constraint.isEditable)
    }

    // MARK: - Joint size limits

    /// The shape a hosted model needs: an arbitrary size on a 16px grid, but
    /// capped in elongation and in total pixels. Numbers follow the OpenAI image
    /// API (§13.2, D1 of `Multi-Engine-Design.md`).
    private static let hosted = SizeConstraint.freeform(
        range: 512...3_840,
        step: 16,
        limits: SizeLimits(maxAspectRatio: 3, pixelBounds: 655_360...8_294_400)
    )

    private func isLegal(_ size: CGSize, _ limits: SizeLimits) -> Bool {
        let long = max(Int(size.width), Int(size.height))
        let short = min(Int(size.width), Int(size.height))
        if let ratio = limits.maxAspectRatio, Double(long) / Double(short) > ratio + 0.0001 {
            return false
        }
        if let pixels = limits.pixelBounds, !pixels.contains(Int(size.width) * Int(size.height)) {
            return false
        }
        return Int(size.width) % 16 == 0 && Int(size.height) % 16 == 0
    }

    @Test("No limits leaves a size exactly as per-dimension bounds left it")
    func noLimitsIsPassthrough() {
        let plain = SizeConstraint.freeform(range: 512...3_840, step: 16)

        #expect(plain.limits.isEmpty)
        // 3840x512 is 7.5:1 and only 1.97M pixels — illegal for the hosted
        // constraint, untouched without limits.
        #expect(
            plain.resolved(CGSize(width: 3_840, height: 512))
                == CGSize(width: 3_840, height: 512))
    }

    @Test(
        "An already-legal size is returned unchanged",
        arguments: [
            CGSize(width: 1_024, height: 1_024),
            CGSize(width: 1_536, height: 1_024),
            CGSize(width: 1_024, height: 1_536),
            CGSize(width: 2_048, height: 2_048),
            CGSize(width: 3_840, height: 2_160),
        ]
    )
    func legalSizeUnchanged(size: CGSize) {
        #expect(Self.hosted.resolved(size) == size)
    }

    /// Correcting elongation reduces the long edge and leaves the short one, so
    /// the result is never larger than what was asked for.
    @Test(
        "An over-elongated size has its long edge brought in",
        arguments: [
            (CGSize(width: 3_840, height: 512), CGSize(width: 1_536, height: 512)),
            (CGSize(width: 512, height: 3_840), CGSize(width: 512, height: 1_536)),
        ]
    )
    func elongationCorrected(requested: CGSize, expected: CGSize) {
        let resolved = Self.hosted.resolved(requested)

        #expect(resolved == expected)
        #expect(isLegal(resolved, Self.hosted.limits))
    }

    /// Over-budget scales both edges, so the shape survives. Nibbling one edge
    /// would hand back something squarer than the user asked for.
    @Test("An over-budget size is scaled down, keeping its shape")
    func pixelCeilingScalesProportionally() {
        let requested = CGSize(width: 3_840, height: 2_400)  // 1.6:1, 9.2M pixels
        let resolved = Self.hosted.resolved(requested)

        #expect(Int(resolved.width) * Int(resolved.height) <= 8_294_400)
        #expect(isLegal(resolved, Self.hosted.limits))
        let requestedRatio = 3_840.0 / 2_400.0
        let resolvedRatio = Double(resolved.width) / Double(resolved.height)
        #expect(abs(resolvedRatio - requestedRatio) < 0.05)
        // Scaled down, not up.
        #expect(resolved.width <= requested.width && resolved.height <= requested.height)
    }

    /// The one case that enlarges. A floor cannot be met by shrinking, and the
    /// alternative is a request the service rejects.
    @Test("An under-budget size is scaled up to reach the floor")
    func pixelFloorScalesUp() {
        let requested = CGSize(width: 512, height: 512)  // 262k pixels, below the floor
        let resolved = Self.hosted.resolved(requested)

        #expect(Int(resolved.width) * Int(resolved.height) >= 655_360)
        #expect(isLegal(resolved, Self.hosted.limits))
        #expect(resolved.width >= requested.width && resolved.height >= requested.height)
    }

    /// Both corrections at once, and in the order that matters: the ratio step
    /// moves one edge, the budget steps scale both, so satisfying the budget
    /// cannot undo the ratio.
    @Test("A size violating both rules ends up legal")
    func bothRulesCorrected() {
        // 12:1 and far under the pixel floor.
        let resolved = Self.hosted.resolved(CGSize(width: 6_144, height: 512))

        #expect(isLegal(resolved, Self.hosted.limits))
    }

    @Test(
        "Every corrected size is legal, whatever was asked for",
        arguments: [
            CGSize(width: 1, height: 1),
            CGSize(width: 10_000, height: 10_000),
            CGSize(width: 10_000, height: 1),
            CGSize(width: 1, height: 10_000),
            CGSize(width: 640, height: 4_000),
            CGSize(width: 3_000, height: 700),
            CGSize(width: 1_023, height: 1_025),
            CGSize(width: 2_560, height: 1_440),
        ]
    )
    func correctionAlwaysLands(requested: CGSize) {
        let resolved = Self.hosted.resolved(requested)

        #expect(isLegal(resolved, Self.hosted.limits))
        #expect((512...3_840).contains(Int(resolved.width)))
        #expect((512...3_840).contains(Int(resolved.height)))
    }

    @Test("Resolving is idempotent: a corrected size does not move again")
    func correctionIsIdempotent() {
        for requested in [
            CGSize(width: 1, height: 1),
            CGSize(width: 10_000, height: 1),
            CGSize(width: 3_840, height: 2_400),
            CGSize(width: 640, height: 4_000),
        ] {
            let once = Self.hosted.resolved(requested)
            #expect(Self.hosted.resolved(once) == once)
        }
    }

    // MARK: - Quality

    /// Hosted vocabulary. Both local engines declare it unsupported, so `plan`
    /// resolves it to nothing and no image records a quality it did not have.
    @Test("Neither local model claims a quality")
    func localModelsHaveNoQuality() throws {
        let temp = try TempDirectory()
        let sdURL = try temp.subdirectory("sd")
        try makeSDModelFixture(at: sdURL)
        let kleinURL = try temp.subdirectory("klein")
        try makeKleinModelFixture(at: kleinURL)

        let sd = try #require(SDModel(url: sdURL, name: "sd", controlNet: []))
        let klein = try #require(IrisFluxKleinModel(url: kleinURL, name: "klein"))

        #expect(!sd.constraints.quality.isSupported)
        #expect(!klein.constraints.quality.isSupported)
        #expect(sd.constraints.quality.resolved(.high) == nil)
        #expect(klein.constraints.quality.resolved(.high) == nil)
    }

    /// Raw values reach the wire and the image metadata, so they are pinned. §6
    /// learned with `Scheduler` what it costs to let a display string double as a
    /// persisted identifier.
    @Test("Quality identifiers are stable and distinct from their labels")
    func qualityIdentifiersAreStable() {
        #expect(ImageQuality.auto.rawValue == "auto")
        #expect(ImageQuality.low.rawValue == "low")
        #expect(ImageQuality.medium.rawValue == "medium")
        #expect(ImageQuality.high.rawValue == "high")
        #expect(ImageQuality.allCases.count == 4)
        // A label is free to be reworded or localized; an identifier is not.
        #expect(ImageQuality.auto.displayName != ImageQuality.auto.rawValue)
    }

    /// The forward-compatibility rule. An image written by a later build naming a
    /// quality this one does not have must leave the sidebar alone rather than be
    /// read as `auto` — that would show a value the image never used, which is the
    /// scheduler import defect in a new place.
    @Test(
        "Only a recognised recorded quality is read back",
        arguments: [
            ("auto", ImageQuality.auto),
            ("low", .low),
            ("medium", .medium),
            ("high", .high),
        ]
    )
    func recognisedQualityIsRead(recorded: String, expected: ImageQuality) {
        #expect(ImageQuality(recorded) == expected)
    }

    @Test(
        "An unrecognised or absent quality reads as nothing",
        arguments: ["", "ultra", "Auto", "HIGH", "low ", "0"]
    )
    func unrecognisedQualityIsNil(recorded: String) {
        #expect(ImageQuality(recorded) == nil)
    }

    @Test("An offered quality is honoured and an unoffered one falls back")
    func qualityChoiceResolution() {
        let offered = ChoiceConstraint<ImageQuality>.oneOf([.auto, .low, .high])

        #expect(offered.resolved(.high) == .high)
        // Not offered, so the first is used rather than the request being rejected
        // — the same rule every other choice constraint follows.
        #expect(offered.resolved(.medium) == .auto)
        #expect(ChoiceConstraint<ImageQuality>.pinned(.low).resolved(.high) == .low)
    }

    // MARK: - Choices

    @Test("A pinned choice ignores the request, an offered one is honoured")
    func choiceResolution() {
        let pinned = ChoiceConstraint<Scheduler>.pinned(.discreteFlowScheduler)
        #expect(pinned.resolved(.pndmScheduler) == .discreteFlowScheduler)
        #expect(!pinned.isEditable)

        let offered = ChoiceConstraint<Scheduler>.oneOf(Scheduler.allCases)
        #expect(offered.resolved(.pndmScheduler) == .pndmScheduler)
        #expect(offered.isEditable)

        #expect(ChoiceConstraint<Scheduler>.unsupported.resolved(.pndmScheduler) == nil)
    }

    /// A scheduler persisted from another engine's model may not be on offer here.
    @Test("A choice not on offer falls back rather than failing")
    func choiceFallsBack() {
        let offered = ChoiceConstraint<Scheduler>.oneOf([.pndmScheduler])

        #expect(offered.resolved(.discreteFlowScheduler) == .pndmScheduler)
    }

    // MARK: - Input images and ControlNet

    /// Nesting strength inside the input-images constraint is what makes
    /// "strength but no image" unrepresentable. Iris is the case that needs it: it
    /// takes images and ignores strength.
    @Test("Strength is unreachable without an input image")
    func strengthRequiresInputImage() {
        #expect(InputImagesConstraint.unsupported.strength == .unsupported)
        #expect(!InputImagesConstraint.unsupported.isSupported)

        let inputImageOnly = InputImagesConstraint.supported(maxCount: 1, strength: .unsupported)
        #expect(inputImageOnly.isSupported)
        #expect(inputImageOnly.strength.resolved(0.5) == nil)
    }

    @Test("An unsupported constraint accepts nothing and counts zero")
    func unsupportedInputImagesTakesNothing() {
        let constraint = InputImagesConstraint.unsupported

        #expect(constraint.maxCount == 0)
        #expect(!constraint.acceptsMultiple)
        #expect(constraint.resolved([makeInputImage(), makeInputImage()]).isEmpty)
    }

    @Test("Only a constraint that takes more than one is multiple")
    func acceptsMultipleFollowsMaxCount() {
        #expect(
            !InputImagesConstraint.supported(maxCount: 1, strength: .unsupported)
                .acceptsMultiple)
        #expect(
            InputImagesConstraint.supported(maxCount: 2, strength: .unsupported)
                .acceptsMultiple)
    }

    /// The front of the list, not any other subset: order is meaningful to the
    /// engines — Core ML denoises from the first — and the images a user added first
    /// are the ones they meant most.
    @Test("Extra images are dropped from the end")
    func resolvedKeepsLeadingImages() {
        let first = makeInputImage(name: "first.png")
        let second = makeInputImage(name: "second.png")
        let third = makeInputImage(name: "third.png")
        let constraint = InputImagesConstraint.supported(maxCount: 2, strength: .unsupported)

        #expect(constraint.resolved([first, second, third]) == [first, second])
        #expect(constraint.resolved([first]) == [first])
        #expect(constraint.resolved([]).isEmpty)
    }

    /// A guard against metadata that claims an image the request never carried.
    /// Data and names come out of one pass precisely so they cannot disagree.
    @Test("Preparing truncates and names only what survives")
    func preparedPairsDataWithNames() {
        let named = makeInputImage(name: "kept.png")
        let unnamed = makeInputImage(name: nil)
        let dropped = makeInputImage(name: "dropped.png")
        let constraint = InputImagesConstraint.supported(maxCount: 2, strength: .unsupported)

        let prepared = constraint.prepared(
            [named, unnamed, dropped],
            scaledTo: CGSize(width: 16, height: 16)
        )

        // Two images, because the third is past the cap.
        #expect(prepared.data.count == 2)
        // One name, because the second image never had one — and crucially *not*
        // "dropped.png", whose image was not sent.
        #expect(prepared.names == ["kept.png"])
    }

    @Test("An unsupported constraint prepares nothing even when handed images")
    func preparedRespectsUnsupported() {
        let prepared = InputImagesConstraint.unsupported.prepared(
            [makeInputImage(name: "ignored.png")],
            scaledTo: CGSize(width: 16, height: 16)
        )

        #expect(prepared.data.isEmpty)
        #expect(prepared.names.isEmpty)
    }

    private func makeInputImage(name: String? = nil) -> InputImage {
        InputImage(image: makeCGImage(), name: name)
    }

    @Test("ControlNet carries the names the model can actually use")
    func controlNetCarriesNames() {
        #expect(ControlNetConstraint.unsupported.names.isEmpty)
        #expect(!ControlNetConstraint.unsupported.isSupported)

        let supported = ControlNetConstraint.supported(names: ["canny", "depth"])
        #expect(supported.isSupported)
        #expect(supported.names == ["canny", "depth"])
    }
}

/// Pins what the sidebar will actually show for the two real models.
///
/// The views ask the constraints these same questions, so a regression shows up as
/// a failing expectation here rather than as a control quietly reappearing in the
/// sidebar.
struct ModelVisibilityTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func makeSDModel(inputSize: CGSize?, controlNets: [SDControlNet] = []) throws -> SDModel
    {
        let url = try temp.subdirectory("sd-\(UUID().uuidString)")
        try makeSDModelFixture(at: url, inputSize: inputSize)
        return try #require(SDModel(url: url, name: "sd-model", controlNet: controlNets))
    }

    @Test("Klein hides everything a distilled model cannot use")
    func kleinHidesUnusableControls() {
        let constraints = IrisFluxKleinModel.constraints

        #expect(!constraints.supportsNegativePrompt)
        #expect(!constraints.guidanceScale.isSupported)
        #expect(!constraints.controlNet.isSupported)
        #expect(!constraints.inputImages.strength.isSupported)
        // Shown, but disabled: seeing "4" explains the model better than an
        // absent row does.
        #expect(constraints.steps.isSupported)
        #expect(!constraints.steps.isEditable)
        #expect(!constraints.scheduler.isEditable)
        // Images are accepted as references, up to what `iris_multiref` takes.
        #expect(constraints.inputImages.isSupported)
        #expect(constraints.inputImages.acceptsMultiple)
        #expect(constraints.inputImages.maxCount == IrisEngine.maxReferenceImages)
    }

    @Test("A fixed-size Core ML model shows its size read-only")
    func fixedSizeIsReadOnly() throws {
        let model = try makeSDModel(inputSize: CGSize(width: 512, height: 768))

        #expect(!model.constraints.size.isEditable)
        #expect(model.constraints.size.pinnedSizes == [CGSize(width: 512, height: 768)])
    }

    @Test("A Core ML model with no fixed size stays editable")
    func freeformSizeIsEditable() throws {
        let model = try makeSDModel(inputSize: nil)

        #expect(model.constraints.size.isEditable)
        #expect(model.constraints.size.bounds == 64...1_792)
        #expect(model.constraints.size.step == 16)
    }

    /// ControlNet needs a fixed size to scale guide images to, and `SDModel`
    /// reports no matching nets for a freeform model, so the section is hidden
    /// rather than shown and then ignored.
    @Test("ControlNet is unsupported without a fixed size")
    func controlNetNeedsFixedSize() throws {
        let controlNetDir = try temp.subdirectory("controlnet")
        let netURL = controlNetDir.appending(path: "canny.mlmodelc")
        try makeControlNetFixture(at: netURL, size: CGSize(width: 512, height: 512))
        let net = try #require(SDControlNet(url: netURL))

        let fixed = try makeSDModel(inputSize: CGSize(width: 512, height: 512), controlNets: [net])
        #expect(fixed.constraints.controlNet.isSupported)
        #expect(fixed.constraints.controlNet.names == ["canny"])

        let freeform = try makeSDModel(inputSize: nil, controlNets: [net])
        #expect(!freeform.constraints.controlNet.isSupported)
    }

    @Test("Core ML keeps every option the sidebar offered before")
    func coreMLKeepsFullOptionSet() throws {
        let constraints = try makeSDModel(inputSize: nil).constraints

        #expect(constraints.supportsNegativePrompt)
        #expect(constraints.steps.bounds == 1...50)
        // Both released sliders let a typed value past their maximum.
        #expect(constraints.steps.allowsValuesAboveBounds)
        #expect(constraints.numberOfImages.allowsValuesAboveBounds)
        #expect(constraints.steps.resolved(75) == 75)
        #expect(constraints.guidanceScale.bounds == 1...20)
        #expect(constraints.inputImages.strength.bounds == 0...1)
        #expect(constraints.numberOfImages.bounds == 1...100)
        #expect(constraints.scheduler.options == Scheduler.allCases)
    }
}

/// A scheduler's raw value is persisted in `UserDefaults` and written into image
/// metadata, so it is an identifier. Its label is not.
struct SchedulerIdentityTests {
    @Test("Every scheduler keeps its stable identifier", arguments: Scheduler.allCases)
    func identifiersAreStable(scheduler: Scheduler) {
        // Pinned deliberately: changing one of these orphans a stored preference
        // and stops existing images from parsing their metadata.
        let expected: [Scheduler: String] = [
            .pndmScheduler: "PNDM",
            .dpmSolverMultistepScheduler: "DPM-Solver++",
            .discreteFlowScheduler: "Flow Match Euler Discrete",
        ]

        #expect(scheduler.rawValue == expected[scheduler])
        #expect(Scheduler(rawValue: scheduler.rawValue) == scheduler)
    }

    @Test("Every scheduler has a label", arguments: Scheduler.allCases)
    func displayNamesExist(scheduler: Scheduler) {
        #expect(!scheduler.displayName.isEmpty)
    }
}
