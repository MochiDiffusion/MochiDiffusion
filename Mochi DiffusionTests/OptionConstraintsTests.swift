//
//  OptionConstraintsTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins normalization, which is where §6's "normalize, throw only if impossible"
/// decision actually lives.
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
