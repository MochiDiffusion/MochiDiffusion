//
//  PreferenceMigration.swift
//  Mochi Diffusion
//

import Foundation

/// One-time migration of the pre-multi-engine selected-model preference.
///
/// Before engines existed, the selection was an absolute `URL` under the models
/// directory. It is now a ``ModelID``: an engine plus the model directory's name.
/// The engine is not recoverable from the URL, so it has to be re-derived from
/// what is on disk.
///
/// The classifier here is **frozen**. It reproduces the sniff order
/// `ModelRepository.load` used at the time of migration — Iris/Klein first, then
/// Core ML Stable Diffusion — because that order is what decided which kind of
/// model the user was actually looking at. It exists only to interpret old
/// preferences and must not become a general rule: engines discover
/// independently and the registry arbitrates nothing (§5.5 of
/// `Multi-Engine-Design.md`). Delete this type once the migration window closes.
///
/// Deciding and persisting are separate so the decision can be tested without
/// `UserDefaults` at all. ``ConfigStore/migrateSelectedModelIfNeeded(modelDirectory:)``
/// applies the result.
nonisolated enum PreferenceMigration {
    /// Migration never fails destructively. Worst case the selection is left
    /// unset and the app picks the first model — exactly what it already does for
    /// a selection that no longer resolves.
    enum Outcome: Equatable, Sendable {
        /// An engine-qualified selection is already present.
        case alreadyMigrated
        /// No legacy selection to migrate.
        case nothingToMigrate
        /// The legacy URL no longer names a directory any engine recognises.
        case unresolvable
        case migrated(ModelID)
    }

    /// Decides what the engine-qualified selection should become.
    ///
    /// - Parameters:
    ///   - legacyURL: the old `Model` preference, if any.
    ///   - existing: the current engine-qualified selection, if any. Its presence
    ///     is what makes this idempotent.
    ///   - modelDirectory: the models root as configured *now*. The legacy URL is
    ///     absolute and may be spelled differently, which is why only the
    ///     directory name is taken from it.
    static func selectedModel(
        legacyURL: URL?,
        existing: ModelID?,
        modelDirectory: URL
    ) -> Outcome {
        if existing != nil {
            return .alreadyMigrated
        }
        guard let legacyURL else {
            return .nothingToMigrate
        }

        let key = ModelID.localKey(for: legacyURL)
        guard let url = ModelID.localURL(forKey: key, under: modelDirectory),
            let engine = frozenEngineClassification(of: url, name: key)
        else {
            return .unresolvable
        }
        return .migrated(ModelID(engine: engine, key: key))
    }

    /// Which engine the app would have shown this directory as, at the time the
    /// preference was written. Frozen; see the type's documentation.
    private static func frozenEngineClassification(of url: URL, name: String) -> EngineID? {
        if IrisFluxKleinModel(url: url, name: name) != nil {
            return .iris
        }
        if SDModel(url: url, name: name, controlNet: []) != nil {
            return .coreMLStableDiffusion
        }
        return nil
    }
}
