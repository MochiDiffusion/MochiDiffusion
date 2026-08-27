//
//  OptionConstraints.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// What a model can do with one whole-number option.
///
/// Three states rather than a Boolean, because "supported" and "has one fixed
/// value" are different things and the sidebar has to tell them apart: an
/// unsupported control is hidden, a pinned one is shown disabled so the effective
/// value is visible, and an editable one is shown with its bounds.
nonisolated enum IntConstraint: Sendable, Equatable {
    case unsupported
    /// The model always uses this value, whatever the sidebar says. FLUX.2 Klein
    /// is distilled to four steps.
    case pinned(Int)
    /// `bounds` is what a control spans. `acceptsBeyondUpperBound` says the model
    /// will take more than that, which is not a detail — the released step and
    /// image-count sliders pass `strictUpperBound: false`, so typing 75 steps into
    /// a slider that spans to 50 keeps 75. Clamping to `bounds` would show 75 and
    /// generate 50.
    case range(ClosedRange<Int>, step: Int, acceptsBeyondUpperBound: Bool)

    /// The common case, where the control's span is also the limit.
    static func range(_ bounds: ClosedRange<Int>, step: Int) -> IntConstraint {
        .range(bounds, step: step, acceptsBeyondUpperBound: false)
    }

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var isEditable: Bool {
        if case .range = self { return true }
        return false
    }

    /// What a control should span. Not necessarily what the model will accept —
    /// see ``allowsValuesAboveBounds``.
    var bounds: ClosedRange<Int>? {
        if case .range(let bounds, _, _) = self { return bounds }
        return nil
    }

    var step: Int? {
        if case .range(_, let step, _) = self { return step }
        return nil
    }

    /// Whether a value typed above ``bounds`` is honoured rather than clamped.
    /// Maps straight onto `MochiSlider`'s `strictUpperBound`.
    var allowsValuesAboveBounds: Bool {
        if case .range(_, _, let allows) = self { return allows }
        return false
    }

    /// Normalizes `requested` to something this model will accept, or `nil` when
    /// the option does not apply.
    ///
    /// Clamps and snaps rather than rejecting. The sidebar's persisted value
    /// routinely will not fit a newly selected model, and overriding it is
    /// correct behaviour rather than an error — see §6 of
    /// `Multi-Engine-Design.md`.
    func resolved(_ requested: Int) -> Int? {
        switch self {
        case .unsupported:
            return nil
        case .pinned(let value):
            return value
        case .range(let bounds, let step, let acceptsBeyondUpperBound):
            // The lower bound is always enforced; the upper only when the control
            // does not let the user past it.
            let lowered = max(requested, bounds.lowerBound)
            let clamped = acceptsBeyondUpperBound ? lowered : min(lowered, bounds.upperBound)
            guard step > 1 else { return clamped }
            let snapped =
                bounds.lowerBound
                + Int((Double(clamped - bounds.lowerBound) / Double(step)).rounded()) * step
            let floored = max(snapped, bounds.lowerBound)
            return acceptsBeyondUpperBound ? floored : min(floored, bounds.upperBound)
        }
    }
}

/// The same three states for a fractional option — guidance scale, strength.
///
/// `step` is optional, and both current uses pass `nil`. A constraint says what a
/// model will *accept*; nothing in Core ML requires a guidance scale to land on a
/// half or a strength on a twentieth. Those are slider granularity, which
/// `MochiSlider` already applies when it writes the value. Snapping here as well
/// would silently move a number the user typed — 0.42 became 0.40 — for no
/// reason the model cares about. Size is the opposite case and does snap: latent
/// dimensions genuinely have to be multiples of 16.
nonisolated enum DoubleConstraint: Sendable, Equatable {
    case unsupported
    case pinned(Double)
    case range(ClosedRange<Double>, step: Double?)

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var isEditable: Bool {
        if case .range = self { return true }
        return false
    }

    var bounds: ClosedRange<Double>? {
        if case .range(let bounds, _) = self { return bounds }
        return nil
    }

    var step: Double? {
        if case .range(_, let step) = self { return step }
        return nil
    }

    func resolved(_ requested: Double) -> Double? {
        switch self {
        case .unsupported:
            return nil
        case .pinned(let value):
            return value
        case .range(let bounds, let step):
            let clamped = min(max(requested, bounds.lowerBound), bounds.upperBound)
            guard let step, step > 0 else { return clamped }
            let snapped =
                bounds.lowerBound + ((clamped - bounds.lowerBound) / step).rounded() * step
            return min(max(snapped, bounds.lowerBound), bounds.upperBound)
        }
    }
}

/// What sizes a model produces.
///
/// No `unsupported` case: every model produces an image of some size. The
/// distinction that matters is whether the user chooses it.
nonisolated enum SizeConstraint: Sendable, Equatable {
    /// The model produces exactly these sizes and nothing else. Core ML models
    /// are converted at a fixed resolution, so this is usually one entry.
    case pinned([CGSize])
    case freeform(range: ClosedRange<Int>, step: Int)

    var isEditable: Bool {
        if case .freeform = self { return true }
        return false
    }

    var pinnedSizes: [CGSize] {
        if case .pinned(let sizes) = self { return sizes }
        return []
    }

    var bounds: ClosedRange<Int>? {
        if case .freeform(let bounds, _) = self { return bounds }
        return nil
    }

    var step: Int? {
        if case .freeform(_, let step) = self { return step }
        return nil
    }

    func resolved(_ requested: CGSize) -> CGSize {
        switch self {
        case .pinned(let sizes):
            // The requested size if the model offers it, otherwise the first —
            // which for a single-size model is the only answer there is.
            return sizes.contains(requested) ? requested : (sizes.first ?? requested)
        case .freeform(let bounds, let step):
            let dimension = IntConstraint.range(bounds, step: step)
            return CGSize(
                width: dimension.resolved(Int(requested.width)) ?? Int(requested.width),
                height: dimension.resolved(Int(requested.height)) ?? Int(requested.height)
            )
        }
    }
}

/// Whether a starting image is accepted, and what it means if so.
///
/// The strength range is nested rather than a sibling because strength is
/// meaningless without a starting image — and because Iris takes a starting image
/// but ignores strength entirely, which a pair of independent flags could express
/// as the nonsensical "strength but no starting image".
nonisolated enum StartingImageConstraint: Sendable, Equatable {
    case unsupported
    case supported(strength: DoubleConstraint)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var strength: DoubleConstraint {
        if case .supported(let strength) = self { return strength }
        return .unsupported
    }
}

/// Which ControlNets a model can use.
///
/// Carries the names, because for Core ML they depend on the model: only nets
/// converted at the same size and attention type as the model can be used with it.
nonisolated enum ControlNetConstraint: Sendable, Equatable {
    case unsupported
    case supported(names: [String])

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    var names: [String] {
        if case .supported(let names) = self { return names }
        return []
    }
}

/// One choice from a fixed set, or one the model insists on.
nonisolated enum ChoiceConstraint<Option: Hashable & Sendable>: Sendable, Equatable {
    case unsupported
    case pinned(Option)
    case oneOf([Option])

    var isSupported: Bool {
        if case .unsupported = self { return false }
        return true
    }

    var isEditable: Bool {
        if case .oneOf = self { return true }
        return false
    }

    var options: [Option] {
        switch self {
        case .unsupported: return []
        case .pinned(let option): return [option]
        case .oneOf(let options): return options
        }
    }

    /// The one option the model insists on, if it insists. A control shows this
    /// disabled rather than offering a choice it will override.
    var pinnedOption: Option? {
        if case .pinned(let option) = self { return option }
        return nil
    }

    func resolved(_ requested: Option) -> Option? {
        switch self {
        case .unsupported:
            return nil
        case .pinned(let option):
            return option
        case .oneOf(let options):
            return options.contains(requested) ? requested : options.first
        }
    }
}

/// Everything a model will and will not honour, resolved per model rather than
/// per engine.
///
/// Replaces `GenerationCapabilities`, whose Booleans could say "supports steps"
/// but not "always uses four", so the sidebar offered an editable step count that
/// the generator silently overrode and the saved metadata then disagreed with.
nonisolated struct OptionConstraints: Sendable {
    /// A plain `Bool` because there is nothing to constrain here but presence —
    /// a negative prompt is free text or it is not accepted at all.
    var supportsNegativePrompt: Bool
    var size: SizeConstraint
    var steps: IntConstraint
    var guidanceScale: DoubleConstraint
    var scheduler: ChoiceConstraint<Scheduler>
    var startingImage: StartingImageConstraint
    var controlNet: ControlNetConstraint
    var numberOfImages: IntConstraint
    /// How many prompt tokens the model can attend to, for the sidebar's counter.
    /// Not a constraint the sidebar enforces — over-long prompts are truncated by
    /// the model, and warning is more useful than refusing to type.
    var promptTokenLimit: Int?

    /// What the sidebar shows when no model is selected.
    ///
    /// Every control visible with its pre-constraint bounds. There is nothing to
    /// generate with in that state, so hiding controls would just make the
    /// sidebar flicker as models are discovered — and an empty model list is
    /// already reported by its own message.
    static let unconstrained = OptionConstraints(
        supportsNegativePrompt: true,
        size: .freeform(range: 64...1_792, step: 16),
        steps: .range(1...50, step: 1, acceptsBeyondUpperBound: true),
        guidanceScale: .range(1...20, step: nil),
        scheduler: .oneOf(Scheduler.allCases),
        startingImage: .supported(strength: .range(0...1, step: nil)),
        controlNet: .unsupported,
        numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
        promptTokenLimit: nil
    )
}
