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

    // MARK: - Starting image and ControlNet

    /// Nesting strength inside the starting-image constraint is what makes
    /// "strength but no starting image" unrepresentable. Iris is the case that
    /// needs it: it takes a starting image and ignores strength.
    @Test("Strength is unreachable without a starting image")
    func strengthRequiresStartingImage() {
        #expect(StartingImageConstraint.unsupported.strength == .unsupported)
        #expect(!StartingImageConstraint.unsupported.isSupported)

        let inputImageOnly = StartingImageConstraint.supported(strength: .unsupported)
        #expect(inputImageOnly.isSupported)
        #expect(inputImageOnly.strength.resolved(0.5) == nil)
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
        #expect(!constraints.startingImage.strength.isSupported)
        // Shown, but disabled: seeing "4" explains the model better than an
        // absent row does.
        #expect(constraints.steps.isSupported)
        #expect(!constraints.steps.isEditable)
        #expect(!constraints.scheduler.isEditable)
        // A starting image is still accepted, as an input image.
        #expect(constraints.startingImage.isSupported)
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
        #expect(constraints.startingImage.strength.bounds == 0...1)
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
