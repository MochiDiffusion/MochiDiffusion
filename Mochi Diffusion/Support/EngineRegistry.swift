//
//  EngineRegistry.swift
//  Mochi Diffusion
//

import Foundation
import os

/// Holds the engines and runs discovery across them.
///
/// Discovery is per engine and failure-isolated: each engine's result is kept
/// separately, so a missing folder or an absent API key cannot empty the model list
/// for everything else.
actor EngineRegistry {
    /// The engines the app ships with, in registration order. That order decides
    /// only where an engine appears in a list — never which engine owns a model,
    /// and never whether a model is valid.
    static var shipped: [AnyGenerationEngine] {
        [
            AnyGenerationEngine(IrisEngine()),
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
        ]
    }

    /// The shipped engines plus hosted OpenAI generation, which the app does not
    /// currently register.
    ///
    /// Hosted generation is opt-in at the composition root, so the default
    /// registry cannot reach a credential store or hosted runtime.
    static func openAIBeta(
        secrets: any SecretStore,
        fileSystem: FileSystemStore = FileSystemStore()
    ) -> EngineRegistry {
        EngineRegistry(
            engines: shipped + [AnyGenerationEngine(OpenAIImageEngine(secrets: secrets))],
            fileSystem: fileSystem
        )
    }

    /// One engine's discovery result, kept whole so a caller can report a failure
    /// against the engine it belongs to.
    struct Discovery: Sendable {
        let engine: EngineID
        let models: [any EngineModel]
        let failure: (any Error)?
    }

    /// `nonisolated` because the engines are immutable `Sendable` values the sidebar
    /// reads on every request it builds. Discovery stays isolated: it does I/O.
    nonisolated private let engines: [AnyGenerationEngine]
    private let fileSystem: FileSystemStore
    private let logger = Logger()

    init(
        engines: [AnyGenerationEngine],
        fileSystem: FileSystemStore = FileSystemStore()
    ) {
        self.engines = engines
        self.fileSystem = fileSystem
    }

    /// The shipped engine list. Hosted generation must be opted into through
    /// `openAIBeta(secrets:fileSystem:)`.
    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.init(engines: EngineRegistry.shipped, fileSystem: fileSystem)
    }

    nonisolated var engineIDs: [EngineID] {
        engines.map(\.id)
    }

    /// Every engine, in registration order, including ones that are unconfigured or
    /// have no models.
    nonisolated var allEngines: [AnyGenerationEngine] {
        engines
    }

    nonisolated func engine(_ id: EngineID) -> AnyGenerationEngine? {
        engines.first { $0.id == id }
    }

    /// Everything one refresh produces, so a caller applies a single consistent
    /// snapshot rather than pairing one engine's availability with another pass's
    /// models.
    struct Refresh: Sendable {
        let discoveries: [Discovery]
        let availability: [EngineID: EngineAvailability]

        var models: [any EngineModel] { discoveries.allModels }
        var failures: [(engine: EngineID, error: any Error)] { discoveries.failures }
    }

    /// Asks every engine what it has and whether it can be used, concurrently.
    ///
    /// Concurrent because the work is per engine and independent: with a hosted
    /// engine registered, a serial pass would make a slow network round trip delay
    /// the local engines that were ready all along.
    ///
    /// Never throws. An engine that fails contributes its error and no models,
    /// which is what keeps one engine's problem from looking like a global one.
    func refresh(settings: EngineSettings) async -> Refresh {
        // Enumerated once for the whole pass; see `ModelDiscoveryContext`.
        let context = ModelDiscoveryContext(settings: settings, fileSystem: fileSystem)

        var discoveredByEngine: [EngineID: Discovery] = [:]
        var availability: [EngineID: EngineAvailability] = [:]

        await withTaskGroup(of: (EngineID, Discovery, EngineAvailability).self) { group in
            for engine in engines {
                group.addTask {
                    // Both halves of one engine's answer, also concurrently: a
                    // hosted engine will reach the network for each.
                    async let reported = engine.availability(settings)
                    let discovery: Discovery
                    do {
                        let models = try await engine.discoverModels(context)
                        discovery = Discovery(engine: engine.id, models: models, failure: nil)
                    } catch {
                        discovery = Discovery(engine: engine.id, models: [], failure: error)
                    }
                    return (engine.id, discovery, await reported)
                }
            }
            for await (id, discovery, reported) in group {
                discoveredByEngine[id] = discovery
                availability[id] = reported
            }
        }

        for engine in engines {
            guard let failure = discoveredByEngine[engine.id]?.failure else { continue }
            logger.error("\(engine.id.rawValue) discovery failed: \(failure)")
            // A discovery failure is an availability failure. `availability` only
            // asks whether the models folder exists, so a folder that exists and
            // cannot be read answers `.ready` — and the picker would then report
            // "No models found", sending the user after missing models when the
            // folder is the problem.
            //
            // Only `.ready` is overridden. An engine that already said why it cannot
            // be used — no API key, host unreachable — has given the better reason,
            // and its discovery failing is a consequence of it rather than a second
            // fact. Replacing that with a generic message would lose the only one
            // the user can act on.
            guard case .ready = availability[engine.id] else { continue }
            availability[engine.id] = .unreachable(
                String(
                    localized: "Models could not be read",
                    comment: "Engine unavailable because listing its models failed"
                )
            )
        }

        // Re-ordered to registration order, which the task group does not preserve.
        // `allModels` breaks name ties by engine id, and presentation order is
        // supposed to be fixed in code rather than depend on completion timing.
        return Refresh(
            discoveries: engines.compactMap { discoveredByEngine[$0.id] },
            availability: availability
        )
    }

    /// Discovery alone, in registration order, for callers that do not need
    /// availability. Production uses `refresh(settings:)`.
    func discoverAll(settings: EngineSettings) async -> [Discovery] {
        await refresh(settings: settings).discoveries
    }
}

nonisolated extension EngineRegistry.Discovery {
    var isFailure: Bool { failure != nil }
}

/// `nonisolated` is load-bearing. Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
/// an unannotated extension's closures are inferred main-actor-isolated, and
/// `sorted(by:)` calls its predicate synchronously on the current thread — so the
/// sort below traps in `dispatch_assert_queue` rather than failing to compile.
nonisolated extension [EngineRegistry.Discovery] {
    /// Every discovered model, sorted by name — case- and diacritic-insensitively —
    /// then by engine id. The second key matters because two engines can expose the
    /// same directory, and so the same name; without it their order would depend on
    /// dictionary iteration.
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
