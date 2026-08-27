//
//  GenerationEngine.swift
//  Mochi Diffusion
//

import CoreGraphics
import CoreML
import Foundation

/// What a local engine needs to find its models.
///
/// Both local engines share one models directory today, which is why this is a
/// single struct rather than per-engine settings. Phase 5 of
/// `Multi-Engine-Design.md` replaces it with an engine-scoped store, at which
/// point `controlNetDirectory` — meaningful only to Core ML Stable Diffusion —
/// stops being a field every engine has to be handed and ignore.
nonisolated struct EngineSettings: Sendable {
    var modelDirectory: URL
    var controlNetDirectory: URL
}

/// Everything the sidebar currently holds, handed to an engine so it can decide
/// what its own generation needs.
///
/// `Sendable` because `CGImage` is: it is an immutable reference type, and the
/// generation callbacks already hand one across actor boundaries. `plan` is
/// synchronous and `nonisolated`, so it runs in the caller's isolation — the main
/// actor — and produces a `Sendable` plan for the queue.
nonisolated struct GenerationDraft: Sendable {
    var prompt: String
    var negativePrompt: String
    /// The size typed into the sidebar. An engine may override it; a Core ML
    /// model with a fixed input size does.
    var configuredSize: CGSize
    var startingImage: CGImage?
    var startingImageName: String?
    var controlNets: [ControlNetDraft]
    var strength: Float
    var stepCount: Int
    var guidanceScale: Float
    var scheduler: Scheduler
    var seed: UInt32
    var numberOfImages: Int
    var computeUnitPreference: ComputeUnitPreference
    var reduceMemory: Bool
    var safetyChecker: Bool
    var showGenerationPreview: Bool
    var imageDir: String
    var imageType: String
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
/// returns *that engine's* payload type. An earlier version had the payload
/// already erased to `any Sendable` here, which meant an engine could return the
/// wrong one with no diagnostic and the mismatch surfaced only when a generator
/// unwrapped it — after `GenerationService` had dequeued the request and
/// published it as current. ``erased()`` widens it once, at the boundary where
/// the heterogeneous queue genuinely needs it.
nonisolated struct GenerationPlan<Payload: Sendable>: Sendable {
    var payload: Payload
    /// The size that will actually be produced.
    var size: CGSize
    var startingImageData: Data?
    var controlNetImageData: [Data]
    var controlNetNames: [String]
    var controlNetImageNames: [String]
    var stepCount: Int
    var scheduler: Scheduler
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
            startingImageData: startingImageData,
            controlNetImageData: controlNetImageData,
            controlNetNames: controlNetNames,
            controlNetImageNames: controlNetImageNames,
            stepCount: stepCount,
            scheduler: scheduler,
            mlComputeUnit: mlComputeUnit,
            startingImageName: startingImageName,
            inputImageNames: inputImageNames
        )
    }
}

/// Whether an engine can be used, and if not, why — in words a picker can show.
///
/// Phase 5 shows unconfigured engines rather than hiding them, because a backend
/// that only appears once it is already configured is one nobody discovers.
nonisolated enum EngineAvailability: Sendable, Equatable {
    case ready
    /// Reachable, but the user has to do something first.
    case needsConfiguration(String)
    /// Should work, but is not answering — an unreachable host, a missing folder.
    case unreachable(String)
}

/// The immutable half of an engine: what it is, what models it has, and — from
/// the next step — how it turns the UI's draft into a request payload.
///
/// Separate from the stateful runtime that owns loaded pipelines and the active
/// generation session (§5.3, §11.2), so the UI can read engine and model facts
/// without an actor hop to something that also holds a multi-gigabyte pipeline.
///
/// Engines never consult each other. Each applies only its own recognition rules
/// to its own configured source, and identity is engine-qualified, so two engines
/// recognising the same directory both return a model and stay distinguishable.
/// There is no ownership arbitration anywhere.
nonisolated protocol GenerationEngineDescriptor: Sendable {
    associatedtype Model: EngineModel
    /// What this engine's generation needs beyond the values every engine
    /// reports. Associated so the engine, its models and its payload stay a
    /// checked triple rather than three things that happen to line up.
    associatedtype Payload: Sendable

    static var id: EngineID { get }
    var displayName: String { get }

    func availability(_ settings: EngineSettings) async -> EngineAvailability

    /// Every model this engine can generate with, in whatever order it finds
    /// them. Callers order the combined list.
    func discoverModels(_ settings: EngineSettings) async throws -> [Model]

    /// Resolves the sidebar's draft into the values this engine will actually use.
    ///
    /// Synchronous, deterministic and side-effect free: no network, no pipeline
    /// loading, no cache mutation. Those belong to `availability`,
    /// `discoverModels`, or the runtime.
    ///
    /// Today this is a relocation of what `GenerationController` and the
    /// per-engine enums used to do between them. Phase 4 makes it the single
    /// place a draft is resolved against a model's constraints, at which point it
    /// starts rejecting unsupported values instead of quietly dropping them.
    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload>
}

/// Type-erased engine, so a heterogeneous registry can hold them.
///
/// Closure-based rather than a wrapper class: each engine stays fully typed
/// internally, and the erasure is one initialiser rather than a parallel
/// hierarchy. `discoverModels` widens to `[any EngineModel]` here because the
/// combined model list is heterogeneous by definition.
nonisolated struct AnyGenerationEngine: Sendable, Identifiable {
    let id: EngineID
    let displayName: String

    private let _availability: @Sendable (EngineSettings) async -> EngineAvailability
    private let _discoverModels: @Sendable (EngineSettings) async throws -> [any EngineModel]
    private let _plan:
        @Sendable (GenerationDraft, any EngineModel) throws -> GenerationPlan<any Sendable>
    private let _accepts: @Sendable (any Sendable) -> Bool

    init<Engine: GenerationEngineDescriptor>(_ engine: Engine) {
        id = Engine.id
        displayName = engine.displayName
        _availability = { await engine.availability($0) }
        _discoverModels = { try await engine.discoverModels($0) }
        _plan = { draft, model in
            // The one place a model is matched back to its engine's concrete
            // type. A mismatch means a model reached the wrong engine, which is
            // a wiring bug rather than anything a user did.
            guard let typed = model as? Engine.Model else {
                throw EngineError.modelDoesNotBelongToEngine(
                    model: model.id, engine: Engine.id)
            }
            return try engine.plan(draft: draft, model: typed).erased()
        }
        _accepts = { $0 is Engine.Payload }
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        await _availability(settings)
    }

    func discoverModels(_ settings: EngineSettings) async throws -> [any EngineModel] {
        try await _discoverModels(settings)
    }

    func plan(draft: GenerationDraft, model: any EngineModel) throws
        -> GenerationPlan<any Sendable>
    {
        try _plan(draft, model)
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

/// Failures that mean the engine wiring is wrong, not that the user configured
/// something badly. They name both ids so a report identifies the mismatch.
nonisolated enum EngineError: Error, Equatable {
    case modelDoesNotBelongToEngine(model: ModelID, engine: EngineID)
    case payloadDoesNotBelongToEngine(engine: EngineID)
    case noEngineForModel(ModelID)
}
