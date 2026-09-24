//
//  EngineSettingsStore.swift
//  Mochi Diffusion
//

import SwiftUI

/// Per-engine persisted values: which engine is selected, and which model each
/// engine was last using.
///
/// Separate from `ConfigStore` because the keys are dynamic. `@AppStorage` binds
/// one property to one literal key, which cannot express `Engine.<id>.…` for a
/// set of engines that grows, so the values are observed stored properties
/// written through to `UserDefaults`.
///
/// The model picker's live selection is `ConfigStore.selectedModel`. These values
/// back the explicit engine picker, which the app does not currently show.
@MainActor
@Observable final class EngineSettingsStore {
    nonisolated enum Key {
        static let selectedEngine = "SelectedEngine"

        static func selectedModel(_ engine: EngineID) -> String {
            "Engine.\(engine.rawValue).SelectedModel"
        }
    }

    private let store: UserDefaults

    private var selectedEngineID: EngineID?
    /// Model selections by engine, read once at init and written through on
    /// change.
    private var selectedModels: [EngineID: ModelID]

    /// - Parameters:
    ///   - store: the defaults to read and write. Tests pass an isolated suite;
    ///     the app uses `.standard`.
    ///   - engines: the engines whose selections are loaded. Only these are read,
    ///     so a key left behind by an engine that no longer exists is ignored
    ///     rather than resurrected.
    init(store: UserDefaults = .standard, engines: [EngineID]) {
        self.store = store
        selectedEngineID = store.string(forKey: Key.selectedEngine).map(EngineID.init(rawValue:))
        selectedModels = [:]
        for engine in engines {
            guard
                let persisted = store.string(forKey: Key.selectedModel(engine)),
                let id = ModelID(persistedValue: persisted)
            else { continue }
            // A key filed under a different engine is corrupt; trusting it would
            // let one engine's selection resolve to another engine's model.
            guard id.engine == engine else { continue }
            selectedModels[engine] = id
        }
    }

    var selectedEngine: EngineID? {
        get { selectedEngineID }
        set {
            guard newValue != selectedEngineID else { return }
            selectedEngineID = newValue
            if let newValue {
                store.set(newValue.rawValue, forKey: Key.selectedEngine)
            } else {
                store.removeObject(forKey: Key.selectedEngine)
            }
        }
    }

    func selectedModel(for engine: EngineID) -> ModelID? {
        selectedModels[engine]
    }

    /// Records `model` as `engine`'s selection.
    ///
    /// Ignores a model belonging to a different engine, which is a wiring bug
    /// rather than something to persist.
    func setSelectedModel(_ model: ModelID?, for engine: EngineID) {
        if let model, model.engine != engine { return }
        guard selectedModels[engine] != model else { return }
        if let model {
            selectedModels[engine] = model
            store.set(model.persistedValue, forKey: Key.selectedModel(engine))
        } else {
            selectedModels.removeValue(forKey: engine)
            store.removeObject(forKey: Key.selectedModel(engine))
        }
    }

    /// Applies the selection migration, if it has not run.
    ///
    /// Written through the properties above rather than straight to `UserDefaults`,
    /// so observers see the change.
    @discardableResult
    func migrateSelectedEngineIfNeeded(from previousSelection: ModelID?, discovered: [ModelID])
        -> EngineSelectionMigration.Outcome
    {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: previousSelection,
            alreadyInItsSlot: previousSelection.map {
                selectedModel(for: $0.engine) == $0
            } ?? false,
            discovered: discovered
        )
        if case .migrated(let id) = outcome {
            setSelectedModel(id, for: id.engine)
            // The engine is adopted only if none is chosen, so the user is not
            // moved off the engine they are working in.
            if selectedEngine == nil {
                selectedEngine = id.engine
            }
        }
        return outcome
    }
}

/// One-time migration of a single `SelectedModel` into `SelectedEngine` plus one
/// key per engine, so switching engines and back does not lose the model in use.
///
/// Runs after `PreferenceMigration`, which turns the legacy `Model` URL into a
/// `SelectedModel`; only that first step needs to match against discovery.
///
/// `SelectedModel` remains the model picker's live selection. This migration
/// seeds the per-engine copy that the explicit engine picker reads.
///
/// Delete both once the migration window closes.
nonisolated enum EngineSelectionMigration {
    enum Outcome: Equatable, Sendable {
        /// The selection is already recorded against its own engine.
        case alreadyMigrated
        /// Nothing to migrate.
        case nothingToMigrate
        /// The selection names nothing discovery found, so there is no engine worth
        /// recording. Retried on the next pass, since the models folder may have
        /// been temporarily unavailable.
        case unresolvable
        case migrated(ModelID)
    }

    /// Decides what the engine-scoped selection should become.
    ///
    /// Migrates only a selection that resolves to a model discovery actually found.
    /// Otherwise `SelectedEngine` would name an engine with no models, and the
    /// controller keeps a chosen engine even when it is empty. Leaving it unset
    /// lets the controller pick the first model instead.
    ///
    /// - Parameter alreadyInItsSlot: whether the selection is already recorded
    ///   against its own engine, which is what "this has run" means. Whether some
    ///   engine is selected says nothing, because `restoreSelection` persists a
    ///   fallback engine.
    static func selection(
        previousSelection: ModelID?,
        alreadyInItsSlot: Bool,
        discovered: [ModelID]
    ) -> Outcome {
        guard let previousSelection else {
            return .nothingToMigrate
        }
        if alreadyInItsSlot {
            return .alreadyMigrated
        }
        guard discovered.contains(previousSelection) else {
            return .unresolvable
        }
        return .migrated(previousSelection)
    }
}
