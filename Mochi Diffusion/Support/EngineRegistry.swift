//
//  EngineRegistry.swift
//  Mochi Diffusion
//

import Foundation
import os

/// Holds the engines and runs discovery across them.
///
/// Discovery is **per engine and failure-isolated**: each engine's result is kept
/// separately, so a missing folder or — once hosted engines exist — an absent API
/// key cannot empty the model list for everything else. The previous
/// implementation threw one error for the whole load, which took every engine's
/// models down with it.
actor EngineRegistry {
    /// Registration order. It affects only where an engine appears in a list;
    /// never which engine owns a model, and never whether a model is valid.
    /// Kept fixed in code rather than derived, so it cannot vary between launches.
    static let defaultEngines: [AnyGenerationEngine] = [
        AnyGenerationEngine(IrisEngine()),
        AnyGenerationEngine(CoreMLStableDiffusionEngine()),
    ]

    /// One engine's discovery result, kept whole so a caller can report a failure
    /// against the engine it belongs to.
    struct Discovery: Sendable {
        let engine: EngineID
        let models: [any EngineModel]
        let failure: (any Error)?
    }

    /// `nonisolated` because the engines are immutable `Sendable` values and the
    /// sidebar reads them on every request it builds, so engine facts need no actor
    /// hop. Discovery stays isolated, because it does I/O.
    nonisolated private let engines: [AnyGenerationEngine]
    private let logger = Logger()

    init(engines: [AnyGenerationEngine] = EngineRegistry.defaultEngines) {
        self.engines = engines
    }

    nonisolated var engineIDs: [EngineID] {
        engines.map(\.id)
    }

    nonisolated func engine(_ id: EngineID) -> AnyGenerationEngine? {
        engines.first { $0.id == id }
    }

    func availability(_ settings: EngineSettings) async -> [EngineID: EngineAvailability] {
        var result: [EngineID: EngineAvailability] = [:]
        for engine in engines {
            result[engine.id] = await engine.availability(settings)
        }
        return result
    }

    /// Discovers every engine's models, in registration order.
    ///
    /// Never throws. An engine that fails contributes its error and no models,
    /// which is what keeps one engine's problem from looking like a global one.
    func discoverAll(settings: EngineSettings) async -> [Discovery] {
        var results: [Discovery] = []
        for engine in engines {
            do {
                let models = try await engine.discoverModels(settings)
                results.append(Discovery(engine: engine.id, models: models, failure: nil))
            } catch {
                logger.error("\(engine.id.rawValue) discovery failed: \(error)")
                results.append(Discovery(engine: engine.id, models: [], failure: error))
            }
        }
        return results
    }
}

nonisolated extension EngineRegistry.Discovery {
    var isFailure: Bool { failure != nil }
}

/// `nonisolated` is load-bearing, not tidiness. With
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, an unannotated extension's
/// closures are inferred main-actor-isolated, and `sorted(by:)` calls its
/// predicate synchronously on whatever thread it is running on — so the sort
/// below trapped in `dispatch_assert_queue` rather than failing to compile.
nonisolated extension [EngineRegistry.Discovery] {
    /// Every discovered model, ordered for one flat picker.
    ///
    /// Sorted by name, case- and diacritic-insensitively, then by engine id.
    /// The second key matters because engines discover independently, so two of
    /// them can expose the same directory and therefore the same name — without it,
    /// that pair's order would depend on dictionary iteration.
    var allModels: [any EngineModel] {
        flatMap(\.models)
            .sorted { lhs, rhs in
                switch lhs.name.compare(
                    rhs.name, options: [.caseInsensitive, .diacriticInsensitive])
                {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.id.engine.rawValue < rhs.id.engine.rawValue
                }
            }
    }

    var failures: [(engine: EngineID, error: any Error)] {
        compactMap { discovery in
            discovery.failure.map { (discovery.engine, $0) }
        }
    }
}
