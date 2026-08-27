//
//  PreferenceMigration.swift
//  Mochi Diffusion
//

import Foundation

/// One-time migration of the pre-multi-engine selected-model preference.
///
/// Before engines existed, the selection was an absolute `URL` under the models
/// directory. It is now a ``ModelID``: an engine plus the model directory's name.
/// The engine is not recoverable from the URL, so it has to be recovered some
/// other way.
///
/// It is recovered by matching against the models **discovery actually found**,
/// rather than by re-running recognition. Calling the model initialisers directly
/// would tie the outcome to live recognition rules: relaxing Klein's required-file
/// list would silently change which engine a legacy URL migrated to, and since
/// users upgrade at different times, two identical preferences would migrate
/// differently depending on which version each user landed on. Matching discovered
/// models means the migration agrees with the list the user is about to see.
///
/// Deciding and persisting are separate so the decision can be tested as a pure
/// function. ``ConfigStore/migrateSelectedModelIfNeeded(discovered:)`` applies it.
///
/// Delete this type once the migration window closes.
nonisolated enum PreferenceMigration {
    /// Migration never fails destructively. Worst case the selection is left
    /// unset and the app picks the first model — exactly what it already does for
    /// a selection that no longer resolves.
    enum Outcome: Equatable, Sendable {
        /// An engine-qualified selection is already present.
        case alreadyMigrated
        /// No legacy selection to migrate.
        case nothingToMigrate
        /// Nothing discovery found matches the legacy selection.
        case unresolvable
        case migrated(ModelID)
    }

    /// Engines that could have produced a legacy selection, most-preferred first.
    ///
    /// This ordering is the only frozen thing here, and it reproduces the sniff
    /// order `ModelRepository.load` used when the legacy format was written —
    /// Klein first, then Core ML — because that order is what decided which kind
    /// of model the user was actually looking at.
    ///
    /// Engines absent from this list are ignored as candidates, so an engine added
    /// in a later phase can never claim an old selection just because it happens
    /// to expose a model with the same key. That is what makes the outcome stable
    /// no matter when a given user upgrades.
    static let legacyEnginePreference: [EngineID] = [.iris, .coreMLStableDiffusion]

    /// Decides what the engine-qualified selection should become.
    ///
    /// - Parameters:
    ///   - legacyURL: the old `Model` preference, if any.
    ///   - existing: the current engine-qualified selection, if any. Its presence
    ///     is what makes this idempotent.
    ///   - discovered: the ids of every model discovery just found. The legacy URL
    ///     is absolute and may be spelled differently from the models root
    ///     configured now, which is why only its last component is used.
    static func selectedModel(
        legacyURL: URL?,
        existing: ModelID?,
        discovered: [ModelID]
    ) -> Outcome {
        if existing != nil {
            return .alreadyMigrated
        }
        guard let legacyURL else {
            return .nothingToMigrate
        }

        let key = ModelID.localKey(for: legacyURL)
        let candidates = discovered.filter { $0.key == key }
        for engine in legacyEnginePreference {
            if let match = candidates.first(where: { $0.engine == engine }) {
                return .migrated(match)
            }
        }
        return .unresolvable
    }
}
