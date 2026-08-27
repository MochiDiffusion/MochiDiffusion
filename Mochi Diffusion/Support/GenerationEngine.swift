//
//  GenerationEngine.swift
//  Mochi Diffusion
//

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

    static var id: EngineID { get }
    var displayName: String { get }

    func availability(_ settings: EngineSettings) async -> EngineAvailability

    /// Every model this engine can generate with, in whatever order it finds
    /// them. Callers order the combined list.
    func discoverModels(_ settings: EngineSettings) async throws -> [Model]
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

    init<Engine: GenerationEngineDescriptor>(_ engine: Engine) {
        id = Engine.id
        displayName = engine.displayName
        _availability = { await engine.availability($0) }
        _discoverModels = { try await engine.discoverModels($0) }
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        await _availability(settings)
    }

    func discoverModels(_ settings: EngineSettings) async throws -> [any EngineModel] {
        try await _discoverModels(settings)
    }
}
