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
/// set of engines that grows. So the values are held as observed stored
/// properties and written through to `UserDefaults`, which also means the
/// `access`/`withMutation` boilerplate `ConfigStore` needs — only because
/// `@AppStorage` is `@ObservationIgnored` — is not needed here.
///
/// `ConfigStore` keeps everything genuinely global. That includes `ModelDir` and
/// `ControlNetDir`: one shared models folder is a settled decision (§7 of
/// `Multi-Engine-Design.md`), so there is no per-engine path to store.
@MainActor
@Observable final class EngineSettingsStore {
    nonisolated enum Key {
        static let selectedEngine = "SelectedEngine"

        static func selectedModel(_ engine: EngineID) -> String {
            "Engine.\(engine.rawValue).SelectedModel"
        }

        /// Reserved for engine-specific values that are not a model selection —
        /// a host, a quality default. Nothing writes it yet; hosted engines will.
        static func options(_ engine: EngineID) -> String {
            "Engine.\(engine.rawValue).Options"
        }
    }

    private let store: UserDefaults

    /// Observed, so the sidebar's engine picker updates when it changes.
    private var selectedEngineID: EngineID?
    /// Model selections by engine, read once at init and written through on
    /// change. Held as one dictionary rather than a property per engine because
    /// the set of engines is not known at compile time.
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
            // A key that names a different engine than the one it is filed under
            // is corrupt rather than merely stale, and trusting it would let one
            // engine's selection resolve to another engine's model.
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
    /// Ignores a model belonging to a different engine: the caller would be
    /// filing a selection where nothing will look for it, and the mismatch is a
    /// wiring bug rather than something to persist.
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

    /// Applies the Phase 2 → Phase 5 selection migration, if it has not run.
    ///
    /// Written through the properties above rather than straight to
    /// `UserDefaults`, so observers see the change.
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
            // The model slot is always filled: that is the migration's actual job,
            // and it is what makes the old selection reappear when the user next
            // switches to that engine.
            setSelectedModel(id, for: id.engine)
            // The engine is only *adopted* if none is chosen. Overwriting it would
            // move a user off whatever they are working in, which is a worse
            // surprise than their old model waiting where they left it.
            if selectedEngine == nil {
                selectedEngine = id.engine
            }
        }
        return outcome
    }
}

/// One-time migration of the Phase 2 selection into the Phase 5 layout.
///
/// Phase 2 stored one engine-qualified `SelectedModel`, because there was no
/// engine picker and therefore only ever one selection. Phase 5 remembers a model
/// per engine, so switching engines and back does not lose the model you were
/// using, which needs `SelectedEngine` plus one key per engine.
///
/// Deliberately a second step rather than an extension of `PreferenceMigration`.
/// A user coming from before engines existed runs both, in order: the legacy
/// `Model` URL becomes a `SelectedModel` by matching what discovery found, and
/// that `SelectedModel` then becomes an engine plus a per-engine key. Folding the
/// two together would mean repeating the discovery-matching that only the first
/// step needs.
///
/// `SelectedModel` is therefore left in place and still written by
/// `PreferenceMigration` — it is a migration waypoint now, not the live value.
///
/// Delete both once the migration window closes.
nonisolated enum EngineSelectionMigration {
    enum Outcome: Equatable, Sendable {
        /// The Phase 2 selection is already recorded against its own engine.
        case alreadyMigrated
        /// No Phase 2 selection to migrate.
        case nothingToMigrate
        /// The Phase 2 selection names nothing discovery found, so there is no
        /// engine worth recording. Retried on the next pass, since the models
        /// folder may simply have been unavailable.
        case unresolvable
        case migrated(ModelID)
    }

    /// Decides what the engine-scoped selection should become.
    ///
    /// Migrates only a selection that resolves to a model discovery actually
    /// found. The Phase 2 value is already engine-qualified, so unlike the legacy
    /// URL there is nothing to *resolve* — but writing it through unchecked would
    /// set `SelectedEngine` to an engine with no models, and the controller
    /// deliberately keeps a chosen engine even when it is empty (§8). An upgrading
    /// user would land on an empty sidebar with no way to see why.
    ///
    /// §8 is about engines the user *chose*, through a picker that only offers
    /// real ones. A stale waypoint is not a choice, so leaving `SelectedEngine`
    /// unset — and letting the controller pick the first model as it always has —
    /// is the right outcome.
    ///
    /// - Parameter alreadyInItsSlot: whether the Phase 2 selection is already
    ///   recorded against its own engine — which is what "this has run" means.
    ///
    ///   It used to mean "some engine is selected", and that signal is not the
    ///   migration's to read: `restoreSelection` persists a fallback engine, so an
    ///   unresolved legacy selection plus a ready hosted engine meant the fallback
    ///   claimed the migration was done and the user's pre-engine model was never
    ///   recovered. The migration deliberately retries across passes, and only its
    ///   own result may end that.
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
