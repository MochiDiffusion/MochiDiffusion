//
//  PreferenceMigration.swift
//  Mochi Diffusion
//

import Foundation

/// One-time migration of the pre-multi-engine selected-model preference.
///
/// Before engines existed, the selection was an absolute `URL` under the models
/// directory. It is now a `ModelID`: an engine plus the model directory's name.
/// The engine is not recoverable from the URL, so it has to be recovered some
/// other way.
///
/// It is recovered by matching against the models discovery actually found, not
/// by re-running recognition. Calling the model initialisers would tie the outcome
/// to live recognition rules, so relaxing them later would change which engine a
/// legacy URL migrates to — and users upgrade at different times, so identical
/// preferences would migrate differently.
///
/// Deciding and persisting are separate, so the decision is a pure function.
/// `ConfigStore.migrateSelectedModelIfNeeded(discovered:)` applies it.
///
/// Delete this type once the migration window closes.
nonisolated enum PreferenceMigration {
    /// Migration never fails destructively. Worst case the selection is left
    /// unset and the app picks the first model, as it does for any selection that
    /// no longer resolves.
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
    /// Frozen: it reproduces the sniff order in use when the legacy format was
    /// written — Klein first, then Core ML — which is what decided the kind of
    /// model the user was looking at. An engine absent from this list is never a
    /// candidate, so a newly added one cannot claim an old selection merely by
    /// exposing a model with the same key.
    static let legacyEnginePreference: [EngineID] = [.iris, .coreMLStableDiffusion]

    /// Decides what the engine-qualified selection should become.
    ///
    /// - Parameters:
    ///   - legacyURL: the old `Model` preference, if any.
    ///   - existing: the current engine-qualified selection, if any. Its presence
    ///     is what makes this idempotent.
    ///   - discovered: the ids of every model discovery just found. Only the legacy
    ///     URL's last component is compared, since it is absolute and may be spelled
    ///     differently from the models root configured now.
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
