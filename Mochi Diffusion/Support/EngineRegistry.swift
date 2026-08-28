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
    /// The engines the app ships, in registration order.
    ///
    /// A function rather than a stored list because the hosted engine needs a
    /// credential store, and which store that is must be a decision the caller
    /// makes — see the `secrets:` initialiser.
    /// - Parameter secrets: where the hosted engine reads its credential.
    static func shipped(secrets: any SecretStore) -> [AnyGenerationEngine] {
        [
            AnyGenerationEngine(IrisEngine()),
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
            AnyGenerationEngine(OpenAIImageEngine(secrets: secrets)),
        ]
    }

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
    private let fileSystem: FileSystemStore
    private let logger = Logger()

    init(
        engines: [AnyGenerationEngine],
        fileSystem: FileSystemStore = FileSystemStore()
    ) {
        self.engines = engines
        self.fileSystem = fileSystem
    }

    /// The shipped engine list.
    ///
    /// `secrets` defaults to a store holding nothing, which is what makes
    /// `EngineRegistry()` safe in a test: the hosted engine is present, so the
    /// list a test sees is the real one, but it reports "no key configured"
    /// deterministically and never queries the keychain. Production passes the
    /// real store, and is the only caller that does.
    init(
        secrets: any SecretStore = NoSecretStore(),
        fileSystem: FileSystemStore = FileSystemStore()
    ) {
        self.init(engines: EngineRegistry.shipped(secrets: secrets), fileSystem: fileSystem)
    }

    nonisolated var engineIDs: [EngineID] {
        engines.map(\.id)
    }

    /// Every engine, in registration order — what the picker lists, including
    /// engines that are unconfigured or have no models. Hiding those would make an
    /// engine that only appears once configured impossible to discover (§8).
    nonisolated var allEngines: [AnyGenerationEngine] {
        engines
    }

    nonisolated func engine(_ id: EngineID) -> AnyGenerationEngine? {
        engines.first { $0.id == id }
    }

    /// Everything one refresh produces, so a caller applies a single consistent
    /// snapshot.
    ///
    /// Availability and discovery used to be two separate calls, which let a caller
    /// pair one engine's availability with another pass's models. They are gathered
    /// together here and returned together.
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
            // A discovery failure *is* an availability failure, and merging it here
            // rather than in the caller is what stops it being lost. `availability`
            // only asks whether the models folder exists, so a folder that exists
            // and cannot be read answers `.ready`; without this the picker would
            // find an engine that is ready with no models and report "No models
            // found", sending the user after missing models when the folder is the
            // problem.
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

    /// Discovery alone, in registration order.
    ///
    /// Kept for tests that assert discovery without availability. Production uses
    /// ``refresh(settings:)``, so the two halves cannot be paired across passes.
    func discoverAll(settings: EngineSettings) async -> [Discovery] {
        await refresh(settings: settings).discoveries
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
