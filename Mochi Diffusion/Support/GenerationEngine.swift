//
//  GenerationEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import CoreML
import Foundation

/// What a local engine needs to find its models.
///
/// One struct rather than per-engine settings, because the local engines share one
/// models directory. `controlNetDirectory` is meaningful only to Core ML Stable
/// Diffusion; other engines are handed it and ignore it.
nonisolated struct EngineSettings: Sendable {
    var modelDirectory: URL
    var controlNetDirectory: URL
}

/// One discovery pass, with the work that does not vary by engine done once.
///
/// Every local engine scans the same models folder, so the enumeration is shared
/// rather than repeated per engine on every folder-change event.
///
/// Recognition is not shared and cannot be: each engine decides what a directory
/// is by its own rules, so sniffing still costs one pass per engine over the same
/// children.
nonisolated struct ModelDiscoveryContext: Sendable {
    let settings: EngineSettings

    /// A `Result` rather than an array, so an unreadable models folder fails only
    /// the engines that looked at it. A hosted engine never calls
    /// `localModelDirectories()`, so a missing local folder cannot take its models
    /// down with it.
    private let localDirectories: Result<[URL], any Error>

    init(settings: EngineSettings, fileSystem: FileSystemStore = FileSystemStore()) {
        self.settings = settings
        localDirectories = Result { try fileSystem.subDirectories(in: settings.modelDirectory) }
    }

    /// The direct children of the models folder, filtered to directories.
    ///
    /// Throws whatever enumeration threw.
    func localModelDirectories() throws -> [URL] {
        try localDirectories.get()
    }
}

/// Everything the sidebar holds, handed to an engine so it can decide what its own
/// generation needs.
///
/// `plan` is synchronous and `nonisolated`, so it runs in the caller's isolation —
/// the main actor — and produces a `Sendable` plan for the queue.
nonisolated struct GenerationDraft: Sendable {
    var prompt: String
    var negativePrompt: String
    /// The size typed into the sidebar. An engine may override it; a Core ML
    /// model with a fixed input size does.
    var configuredSize: CGSize
    /// The image to denoise from, for a model that does img2img. Distinct from
    /// `inputImages` rather than the first of them: it is scaled to the output size
    /// and carries `strength`.
    var startingImage: InputImage?
    /// Images the model attends to as references, in the order the user added them.
    /// An engine takes as many as its `InputImagesConstraint` allows.
    var inputImages: [InputImage]
    var controlNets: [ControlNetDraft]
    var strength: Float
    var stepCount: Int
    var guidanceScale: Float
    var scheduler: Scheduler
    var quality: ImageQuality
    var seed: UInt32
    var numberOfImages: Int
    var computeUnitPreference: ComputeUnitPreference
    var reduceMemory: Bool
    var safetyChecker: Bool
    var showGenerationPreview: Bool
    var imageDir: String
    var imageType: String
    /// Where the shared ControlNet bundles live. Only Core ML Stable Diffusion
    /// reads it.
    var controlNetDirectory: URL
}

nonisolated struct ControlNetDraft: Sendable {
    var name: String?
    var image: CGImage?
    var imageName: String?
}

/// What an engine resolved a draft into: the values that will be used and
/// recorded, plus its own payload.
///
/// Generic over the payload so the compiler enforces that an engine's `plan`
/// returns that engine's payload type. `erased()` widens it once, at the boundary
/// where the heterogeneous queue needs it.
nonisolated struct GenerationPlan<Payload: Sendable>: Sendable {
    var payload: Payload
    /// The size that will actually be produced.
    var size: CGSize
    /// The images this engine will actually send, already cropped, scaled and
    /// encoded, truncated to what the model accepts.
    ///
    /// A starting image, when the model has one, is element zero, and
    /// `startingImageName` is non-nil exactly then — so a runtime that declared both
    /// can tell its denoising origin from its references. The convention is only
    /// ever written and read by the same engine, which is why it stays here rather
    /// than becoming a second array.
    var inputImageData: [Data]
    var controlNetImageData: [Data]
    var controlNetNames: [String]
    var controlNetImageNames: [String]
    /// `nil` where the model does not use the option at all, so the queue hides a
    /// row rather than printing a number that had no effect. A hosted engine has no
    /// concept of `stepCount` or `scheduler`, which is why those are optional too.
    ///
    /// A runtime that does use one of these reads the resolved value from its own
    /// payload.
    var stepCount: Int?
    var scheduler: Scheduler?
    var strength: Float?
    var guidanceScale: Float?
    var quality: ImageQuality?
    var numberOfImages: Int
    var mlComputeUnit: MLComputeUnits?
    /// Core ML records a starting image; Iris records input images. Same sidebar
    /// state, different field, so the engine decides which one it fills.
    var startingImageName: String?
    var inputImageNames: [String]
}

nonisolated extension GenerationPlan {
    /// Widens the payload for the queue, keeping every resolved value.
    func erased() -> GenerationPlan<any Sendable> {
        GenerationPlan<any Sendable>(
            payload: payload,
            size: size,
            inputImageData: inputImageData,
            controlNetImageData: controlNetImageData,
            controlNetNames: controlNetNames,
            controlNetImageNames: controlNetImageNames,
            stepCount: stepCount,
            scheduler: scheduler,
            strength: strength,
            guidanceScale: guidanceScale,
            quality: quality,
            numberOfImages: numberOfImages,
            mlComputeUnit: mlComputeUnit,
            startingImageName: startingImageName,
            inputImageNames: inputImageNames
        )
    }
}

/// Whether an engine can be used, and if not, why — in words a picker can show.
nonisolated enum EngineAvailability: Sendable, Equatable {
    case ready
    /// Reachable, but the user has to do something first.
    case needsConfiguration(String)
    /// Should work, but is not answering — an unreachable host, a missing folder.
    case unreachable(String)
}

/// The stateful half of an engine: it runs one request at a time and owns whatever
/// that costs — a loaded multi-gigabyte pipeline, a C context, a network session.
///
/// Has no `cancel` method. Cancellation lives on the `GenerationSession` the caller
/// already holds, because a runtime blocking its executor inside a synchronous
/// generation call cannot accept an isolated call until that call returns.
///
/// Results are an awaited throwing callback rather than an event: the caller writes
/// each image to disk before the engine produces the next, and a failed write has
/// to stop the generation.
nonisolated protocol GenerationEngineRuntime: Sendable {
    /// Runs `request` to completion, or until `session` is cancelled.
    ///
    /// Reports phase, progress and preview through `session`; hands each finished
    /// image to `onResult`. Returning normally means the request is done —
    /// including when it stopped early because the session was cancelled.
    func run(
        request: GenerationRequest,
        session: GenerationSession,
        onResult: @escaping @Sendable (GenerationResult) async throws -> Void
    ) async throws

    /// How long this runtime may go without emitting an event or a result before
    /// the queue gives up on it. `nil` — the default — means never.
    ///
    /// A bound on the gap between signs of life, not on total duration: a large
    /// generation may legitimately run for minutes, so any wall-clock budget loose
    /// enough to allow one is too loose to catch a hang.
    ///
    /// Per request, because the bound depends on what the request asked for: a
    /// hosted runtime streaming partial images has a heartbeat and can be held to a
    /// tight idle bound, while one with no intermediate events at all would see the
    /// same number become a total budget.
    ///
    /// The queue enforces it, since it owns the request lifecycle and can guarantee
    /// an expiry releases the drain exactly as a completion does. Local runtimes
    /// leave this `nil`.
    func idleTimeout(for request: GenerationRequest) -> Duration?

    /// Whether stopping this runtime leaves work running somewhere we cannot reach.
    /// `false` — the default — for anything in this process.
    ///
    /// A hosted service may finish an image we stopped waiting for, and bill for it,
    /// so the UI says so rather than implying a cancel is free.
    var cancellationMayLeaveWorkBilled: Bool { get }
}

nonisolated extension GenerationEngineRuntime {
    func idleTimeout(for request: GenerationRequest) -> Duration? { nil }
    var cancellationMayLeaveWorkBilled: Bool { false }
}

/// The immutable half of an engine: what it is, what models it has, and how it
/// turns the UI's draft into a request payload.
///
/// Separate from `GenerationEngineRuntime`, which owns loaded pipelines and the
/// active generation, so the UI can read engine and model facts without an actor
/// hop to something holding a multi-gigabyte pipeline.
///
/// Engines never consult each other. Each applies only its own recognition rules to
/// its own source, and identity is engine-qualified, so two engines recognising the
/// same directory both return a model and stay distinguishable. There is no
/// ownership arbitration.
nonisolated protocol GenerationEngineDescriptor: Sendable {
    associatedtype Model: EngineModel
    /// What this engine's generation needs beyond the values every engine reports.
    /// Associated, so the engine, its models and its payload stay a checked triple.
    associatedtype Payload: Sendable

    static var id: EngineID { get }
    var displayName: String { get }

    func availability(_ settings: EngineSettings) async -> EngineAvailability

    /// Every model this engine can generate with, in whatever order it finds them.
    /// Callers order the combined list.
    ///
    /// A local engine takes its candidate directories from
    /// `context.localModelDirectories()` rather than enumerating for itself.
    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model]

    /// Resolves the sidebar's draft into the values this engine will actually use.
    ///
    /// Synchronous, deterministic and side-effect free: no network, no pipeline
    /// loading, no cache mutation. Those belong to `availability`,
    /// `discoverModels`, or the runtime.
    ///
    /// This is the only place a draft is resolved against a model's constraints.
    /// Values out of range are normalized rather than rejected — a size persisted
    /// from another model is not an error — so it throws only for a combination no
    /// normalization can rescue.
    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload>

    /// The model this engine would use to produce `size`, when its models are
    /// per-size variants rather than one model that accepts any size.
    ///
    /// Core ML models are converted at a fixed resolution and usually ship as a
    /// set — `foo_512x768` beside `foo_768x512` — so asking for a different size
    /// means selecting a different model. `OptionConstraints` cannot express
    /// that relationship, and it drives both the sidebar's width/height swap and
    /// the Info panel's copy-size button.
    ///
    /// Returns `nil` when there is no such model, which is the default and what
    /// every engine with freeform sizes answers.
    func model(forSize size: CGSize, among candidates: [Model], current: Model) -> Model?

    /// Makes the runtime that executes this engine's requests.
    ///
    /// Called once per engine and the result reused, so a loaded pipeline survives
    /// between requests.
    func makeRuntime() -> any GenerationEngineRuntime
}

/// Type-erased engine, so a heterogeneous registry can hold them.
///
/// `discoverModels` widens to `[any EngineModel]` here, since the combined model
/// list is heterogeneous by definition.
nonisolated struct AnyGenerationEngine: Sendable, Identifiable {
    let id: EngineID
    let displayName: String

    private let _availability: @Sendable (EngineSettings) async -> EngineAvailability
    private let _discoverModels: @Sendable (ModelDiscoveryContext) async throws -> [any EngineModel]
    private let _plan:
        @Sendable (GenerationDraft, any EngineModel) throws -> GenerationPlan<any Sendable>
    private let _accepts: @Sendable (any Sendable) -> Bool
    private let _makeRuntime: @Sendable () -> any GenerationEngineRuntime
    private let _modelForSize:
        @Sendable (CGSize, [any EngineModel], any EngineModel) -> (any EngineModel)?

    init<Engine: GenerationEngineDescriptor>(_ engine: Engine) {
        id = Engine.id
        displayName = engine.displayName
        _availability = { await engine.availability($0) }
        _discoverModels = { try await engine.discoverModels($0) }
        _plan = { draft, model in
            // The one place a model is matched back to its engine's concrete type.
            // A mismatch is a wiring bug, not something a user did.
            guard let typed = model as? Engine.Model else {
                throw EngineError.modelDoesNotBelongToEngine(
                    model: model.id, engine: Engine.id)
            }
            return try engine.plan(draft: draft, model: typed).erased()
        }
        _accepts = { $0 is Engine.Payload }
        _makeRuntime = { engine.makeRuntime() }
        _modelForSize = { size, candidates, current in
            guard let current = current as? Engine.Model else { return nil }
            return engine.model(
                forSize: size,
                among: candidates.compactMap { $0 as? Engine.Model },
                current: current
            )
        }
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        await _availability(settings)
    }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [any EngineModel] {
        try await _discoverModels(context)
    }

    func plan(draft: GenerationDraft, model: any EngineModel) throws
        -> GenerationPlan<any Sendable>
    {
        try _plan(draft, model)
    }

    func makeRuntime() -> any GenerationEngineRuntime {
        _makeRuntime()
    }

    func model(
        forSize size: CGSize,
        among candidates: [any EngineModel],
        current: any EngineModel
    ) -> (any EngineModel)? {
        _modelForSize(size, candidates, current)
    }

    /// Whether `payload` is the kind this engine produces.
    ///
    /// Checked where a request enters the queue, not where a generator finally
    /// unwraps it: by then the request has been dequeued and published as
    /// current, and the queue cannot un-publish it.
    func accepts(payload: any Sendable) -> Bool {
        _accepts(payload)
    }
}

nonisolated extension GenerationEngineDescriptor {
    /// One model per engine that accepts whatever size it is given is the common
    /// case, so the default answer is "no other model".
    func model(forSize size: CGSize, among candidates: [Model], current: Model) -> Model? {
        nil
    }
}

/// Failures that mean the engine wiring is wrong, not that the user configured
/// something badly. They name both ids so a report identifies the mismatch.
nonisolated enum EngineError: Error, Equatable {
    case modelDoesNotBelongToEngine(model: ModelID, engine: EngineID)
    case payloadDoesNotBelongToEngine(engine: EngineID)
    case noEngineForModel(ModelID)
}
