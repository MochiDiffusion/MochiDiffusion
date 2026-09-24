//
//  OptionConstraints.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

/// What a model can do with one whole-number option — a step count, an image
/// count.
nonisolated enum IntConstraint: Sendable, Equatable {
    case unsupported
    /// The model always uses this value, whatever the sidebar says. FLUX.2 Klein
    /// is distilled to four steps.
    case pinned(Int)
    /// `bounds` is what a control spans; `acceptsBeyondUpperBound` says the model
    /// will take more than that.
    ///
    /// The step and image-count sliders pass `strictUpperBound: false`, which keeps
    /// a typed value above the maximum, so the constraint must accept it too or the
    /// sidebar would show one value while the request used another.
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
    /// see `allowsValuesAboveBounds`.
    var bounds: ClosedRange<Int>? {
        if case .range(let bounds, _, _) = self { return bounds }
        return nil
    }

    var step: Int? {
        if case .range(_, let step, _) = self { return step }
        return nil
    }

    /// Whether a value typed above `bounds` is honoured rather than clamped.
    /// Maps straight onto `MochiSlider`'s `strictUpperBound`.
    var allowsValuesAboveBounds: Bool {
        if case .range(_, _, let allows) = self { return allows }
        return false
    }

    /// Normalizes `requested` to something this model will accept, or `nil` when
    /// the option does not apply.
    ///
    /// Clamps and snaps rather than rejecting: a value persisted from a previously
    /// selected model routinely will not fit the current one, and overriding it is
    /// correct behaviour rather than an error.
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

/// What a model can do with one fractional option — a guidance scale, a strength.
///
/// `step` is usually `nil`: a constraint says what the model will *accept*, and
/// granularity belongs to the control. `MochiSlider` applies its own when it writes
/// the value, so snapping here would move a typed number for no reason the model
/// cares about. `SizeConstraint` does snap, since latent dimensions have to be
/// multiples of 16.
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
    case freeform(range: ClosedRange<Int>, step: Int, limits: SizeLimits)

    /// The common case, where each dimension's bounds are the whole story.
    static func freeform(range: ClosedRange<Int>, step: Int) -> SizeConstraint {
        .freeform(range: range, step: step, limits: .none)
    }

    var isEditable: Bool {
        if case .freeform = self { return true }
        return false
    }

    var pinnedSizes: [CGSize] {
        if case .pinned(let sizes) = self { return sizes }
        return []
    }

    var bounds: ClosedRange<Int>? {
        if case .freeform(let bounds, _, _) = self { return bounds }
        return nil
    }

    var step: Int? {
        if case .freeform(_, let step, _) = self { return step }
        return nil
    }

    var limits: SizeLimits {
        if case .freeform(_, _, let limits) = self { return limits }
        return .none
    }

    func resolved(_ requested: CGSize) -> CGSize {
        switch self {
        case .pinned(let sizes):
            // The requested size if the model offers it, otherwise the first —
            // which for a single-size model is the only answer there is.
            return sizes.contains(requested) ? requested : (sizes.first ?? requested)
        case .freeform(let bounds, let step, let limits):
            let dimension = IntConstraint.range(bounds, step: step)
            let snapped = CGSize(
                width: dimension.resolved(Int(requested.width)) ?? Int(requested.width),
                height: dimension.resolved(Int(requested.height)) ?? Int(requested.height)
            )
            return limits.applied(to: snapped, bounds: bounds, step: step)
        }
    }
}

/// Rules that constrain a size's dimensions *together*, which per-dimension
/// bounds cannot express.
///
/// The local engines need none of these: a Core ML model's size is pinned, and Iris
/// takes any multiple of 16 within its range. A hosted model does — the OpenAI image
/// API accepts an arbitrary `WIDTHxHEIGHT` on a 16px grid, but also caps how
/// elongated it may be and how many pixels it may total.
///
/// Limits rather than an `aspectRatios` case, because the API takes pixels, not
/// ratios: only the legality of a pair is jointly constrained.
nonisolated struct SizeLimits: Sendable, Equatable {
    /// Largest permitted long-edge ÷ short-edge. `nil` for no cap.
    var maxAspectRatio: Double?
    /// Inclusive bounds on width × height. `nil` for no budget.
    var pixelBounds: ClosedRange<Int>?

    static let none = SizeLimits(maxAspectRatio: nil, pixelBounds: nil)

    var isEmpty: Bool { maxAspectRatio == nil && pixelBounds == nil }

    /// Corrects `size` into the legal region.
    ///
    /// One corrective pass in a fixed order rather than a search: establish the
    /// ratio, then the pixel budget. That order works because the ratio step
    /// changes one edge while both pixel steps scale *both* edges, so satisfying
    /// the budget cannot undo the ratio — which is what would otherwise oscillate.
    ///
    /// Scaling proportionally for the budget, rather than nibbling one edge, also
    /// keeps the shape the user asked for. Being handed 4000x2000 when the cap is
    /// 8.29M pixels should give back something still 2:1, not something square.
    ///
    /// Assumes the limits are self-consistent — a ratio of at least 1, a pixel
    /// range wide enough to contain some size the bounds allow. Nothing validates
    /// that, because the values come from our own engine definitions rather than
    /// from input.
    func applied(to size: CGSize, bounds: ClosedRange<Int>, step: Int) -> CGSize {
        guard !isEmpty else { return size }
        var width = Int(size.width)
        var height = Int(size.height)

        if let maxAspectRatio, maxAspectRatio >= 1 {
            (width, height) = Self.applyingRatio(
                maxAspectRatio, width: width, height: height, bounds: bounds, step: step)
        }

        if let pixelBounds {
            if width * height > pixelBounds.upperBound {
                (width, height) = Self.scaled(
                    width: width, height: height,
                    toward: pixelBounds.upperBound, rounding: .down,
                    bounds: bounds, step: step)
            }
            // Growing to reach a floor is the one case that enlarges an image the
            // user may have asked to shrink. The alternative is sending a request
            // the service will reject, so the size has to move; scaling both edges
            // at least keeps it the shape they chose.
            if width * height < pixelBounds.lowerBound {
                (width, height) = Self.scaled(
                    width: width, height: height,
                    toward: pixelBounds.lowerBound, rounding: .up,
                    bounds: bounds, step: step)
            }
        }

        return CGSize(width: width, height: height)
    }

    /// Brings an over-elongated size into the ratio cap by reducing its long edge.
    ///
    /// Reducing the long edge is always sufficient, and never needs a fallback that
    /// grows the short one: both edges are already inside `bounds`, and a cap of at
    /// least 1 means `short × maxRatio >= short >= bounds.lowerBound`, so the
    /// permitted long edge cannot fall below the floor.
    private static func applyingRatio(
        _ maxRatio: Double, width: Int, height: Int, bounds: ClosedRange<Int>, step: Int
    ) -> (Int, Int) {
        let long = max(width, height)
        let short = min(width, height)
        guard short > 0, Double(long) / Double(short) > maxRatio else { return (width, height) }

        let permittedLong = snap(Double(short) * maxRatio, .down, bounds: bounds, step: step)
        return width >= height ? (permittedLong, height) : (width, permittedLong)
    }

    /// Scales both edges toward a pixel target, preserving the aspect ratio.
    private static func scaled(
        width: Int, height: Int, toward targetPixels: Int,
        rounding: FloatingPointRoundingRule, bounds: ClosedRange<Int>, step: Int
    ) -> (Int, Int) {
        let pixels = Double(width * height)
        guard pixels > 0, targetPixels > 0 else { return (width, height) }
        let factor = (Double(targetPixels) / pixels).squareRoot()
        return (
            snap(Double(width) * factor, rounding, bounds: bounds, step: step),
            snap(Double(height) * factor, rounding, bounds: bounds, step: step)
        )
    }

    /// Rounds to the step grid in the given direction, then clamps to `bounds`.
    /// Rounding direction is explicit so a correction cannot overshoot the limit
    /// it was applied to satisfy.
    private static func snap(
        _ value: Double, _ rounding: FloatingPointRoundingRule,
        bounds: ClosedRange<Int>, step: Int
    ) -> Int {
        guard step > 0 else { return min(max(Int(value), bounds.lowerBound), bounds.upperBound) }
        let steps = (value / Double(step)).rounded(rounding)
        let snapped = Int(steps) * step
        return min(max(snapped, bounds.lowerBound), bounds.upperBound)
    }
}

/// Whether a model denoises from an image, and how far from it it may go.
///
/// A *starting image* is one image the generation begins from — img2img. It is a
/// different thing from an input image, not a special case of one: it is scaled to
/// the output size because that is what will happen to it, exactly one of them
/// means anything, and `strength` says how much of it to keep.
///
/// Strength is nested rather than a sibling so "strength but nothing to apply it
/// to" cannot be expressed.
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

    /// Drops the image when the model does not denoise from one.
    func resolved(_ requested: InputImage?) -> InputImage? {
        isSupported ? requested : nil
    }
}

/// How many images a model attends to as references.
///
/// An *input image* is not a denoising origin. It is conditioning the model looks
/// at while generating, several are meaningful, order is positional, and there is
/// no strength to apply — which is why this carries no strength at all rather than
/// an unsupported one.
///
/// `maxCount` is the model's own limit, not a UI preference: `iris_multiref`
/// accepts up to four references for Klein, and a hosted API states its own cap.
/// Exceeding it is not something to warn about — `resolved(_:)` drops the extras
/// before the request is built, the same as every other constraint.
///
/// Independent of ``StartingImageConstraint``: a model may support either, both,
/// or neither.
nonisolated enum InputImagesConstraint: Sendable, Equatable {
    case unsupported
    case supported(maxCount: Int)

    var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    /// How many images the model will take. Zero when unsupported, so callers can
    /// compare against a count without unwrapping.
    var maxCount: Int {
        if case .supported(let maxCount) = self { return max(0, maxCount) }
        return 0
    }

    /// Truncates `requested` to what the model accepts, keeping the leading
    /// entries.
    ///
    /// Order matters — a reference list is positional — so this keeps the front of
    /// the list rather than any other subset. Dropping from the end matches what
    /// the sidebar shows: the images a user added first are the ones they meant
    /// most.
    func resolved(_ requested: [InputImage]) -> [InputImage] {
        guard case .supported(let maxCount) = self, maxCount > 0 else { return [] }
        guard requested.count > maxCount else { return requested }
        return Array(requested.prefix(maxCount))
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

/// Everything a model will and will not honour.
///
/// Per model rather than per engine, because a Core ML model's size and available
/// ControlNets are fixed by how it was converted.
///
/// Each option distinguishes three states because "supported" and "has one fixed
/// value" lead to different controls: an unsupported option shows no value, a
/// pinned one is shown disabled so its effective value is visible, and an editable
/// one is shown with its bounds.
nonisolated struct OptionConstraints: Sendable {
    /// A plain `Bool` because there is nothing to constrain here but presence —
    /// a negative prompt is free text or it is not accepted at all.
    var supportsNegativePrompt: Bool
    var size: SizeConstraint
    var steps: IntConstraint
    var guidanceScale: DoubleConstraint
    var scheduler: ChoiceConstraint<Scheduler>
    /// Independent of `inputImages`: a model may denoise from an image, attend to
    /// references, do both, or neither.
    var startingImage: StartingImageConstraint
    var inputImages: InputImagesConstraint
    var controlNet: ControlNetConstraint
    /// Hosted vocabulary; the local engines declare `.unsupported`.
    var quality: ChoiceConstraint<ImageQuality>
    var numberOfImages: IntConstraint
    /// How many prompt tokens the model can attend to, for the sidebar's counter.
    /// Not a constraint the sidebar enforces — over-long prompts are truncated by
    /// the model, and warning is more useful than refusing to type.
    var promptTokenLimit: Int?

    /// What the sidebar shows when no model is selected: every control visible,
    /// with permissive bounds.
    ///
    /// There is nothing to generate with in that state, so hiding controls would
    /// only make the sidebar flicker as discovery finishes. An empty model list is
    /// reported by its own message.
    static let unconstrained = OptionConstraints(
        supportsNegativePrompt: true,
        size: .freeform(range: 64...1_792, step: 16),
        steps: .range(1...50, step: 1, acceptsBeyondUpperBound: true),
        guidanceScale: .range(1...20, step: nil),
        scheduler: .oneOf(Scheduler.allCases),
        startingImage: .supported(strength: .range(0...1, step: nil)),
        inputImages: .supported(maxCount: 1),
        controlNet: .unsupported,
        quality: .unsupported,
        numberOfImages: .range(1...100, step: 1, acceptsBeyondUpperBound: true),
        promptTokenLimit: nil
    )
}
