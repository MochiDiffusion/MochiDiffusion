//
//  PreferenceMigrationTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// Getting the selected-model migration wrong loses the model a user had selected,
/// or worse their configured folders, on the launch after an upgrade.
///
/// The decision is a pure function of the legacy URL, the existing selection and
/// what discovery found, so it needs neither `UserDefaults` nor a filesystem.
/// `ConfigStoreMigrationTests` covers applying it, and one case there goes through
/// real discovery to prove the wiring.
struct PreferenceMigrationTests {
    private let coreML = EngineID.coreMLStableDiffusion

    private func legacyURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/Users/someone/models/\(name)")
    }

    // MARK: - Recovering the engine

    @Test("A legacy selection resolves to whichever engine discovered it")
    func migratesToTheDiscoveringEngine() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("sd-model"),
            existing: nil,
            discovered: [
                ModelID(engine: coreML, key: "other"),
                ModelID(engine: coreML, key: "sd-model"),
            ]
        )

        #expect(outcome == .migrated(ModelID(engine: coreML, key: "sd-model")))
    }

    @Test("A legacy selection of an Iris model resolves to the Iris engine")
    func migratesKleinSelection() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("klein-model"),
            existing: nil,
            discovered: [ModelID(engine: .iris, key: "klein-model")]
        )

        #expect(outcome == .migrated(ModelID(engine: .iris, key: "klein-model")))
    }

    /// Once engines discover independently, a directory both recognise yields two
    /// models with the same key. The tiebreak reproduces the sniff order
    /// `ModelRepository.load` used when the legacy preference was written — Klein
    /// first — because that is what the user was actually looking at.
    @Test("A key both engines expose follows the order the old app read them in")
    func ambiguousKeyFollowsTheOldSniffOrder() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("ambiguous"),
            existing: nil,
            discovered: [
                ModelID(engine: coreML, key: "ambiguous"),
                ModelID(engine: .iris, key: "ambiguous"),
            ]
        )

        #expect(outcome == .migrated(ModelID(engine: .iris, key: "ambiguous")))
    }

    /// The property that makes the outcome stable however long a user waits to
    /// upgrade: an engine that did not exist when the legacy format did cannot
    /// claim an old selection, even if it exposes a model with the same key.
    @Test("An engine that postdates the legacy format is never a candidate")
    func laterEnginesAreNotCandidates() {
        let future = EngineID(rawValue: "openai")

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("sd-model"),
            existing: nil,
            discovered: [ModelID(engine: future, key: "sd-model")]
        )

        #expect(outcome == .unresolvable)
        #expect(!PreferenceMigration.legacyEnginePreference.contains(future))
    }

    // MARK: - Nothing to resolve to

    @Test(
        "A legacy selection nothing discovered matches is left unmigrated",
        arguments: [
            "deleted-model",
            "not-a-model",
            "/",
        ]
    )
    func unmatchedSelectionIsUnresolvable(name: String) {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL(name),
            existing: nil,
            discovered: [ModelID(engine: EngineID.coreMLStableDiffusion, key: "sd-model")]
        )

        // Not an error: the app already falls back to the first model for a
        // selection that does not resolve.
        #expect(outcome == .unresolvable)
    }

    @Test("No legacy selection is nothing to migrate")
    func noLegacySelection() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: nil,
            existing: nil,
            discovered: [ModelID(engine: EngineID.coreMLStableDiffusion, key: "sd-model")]
        )

        #expect(outcome == .nothingToMigrate)
    }

    @Test("Nothing discovered at all is unresolvable rather than a crash")
    func emptyDiscoveryIsUnresolvable() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("sd-model"),
            existing: nil,
            discovered: []
        )

        #expect(outcome == .unresolvable)
    }

    // MARK: - Path spelling and idempotency

    /// The legacy value is an absolute URL written by a previous launch and may be
    /// spelled differently from the root configured now — the mismatch that
    /// motivated key-based identity. Only the last component is used.
    @Test(
        "The legacy URL's spelling does not affect the migrated key",
        arguments: [
            "/var/models/sd-model",
            "/private/var/models/sd-model",
            "/var/models/sd-model/",
            "/somewhere/else/entirely/sd-model",
        ]
    )
    func spellingDoesNotAffectTheKey(path: String) {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: URL(fileURLWithPath: path),
            existing: nil,
            discovered: [ModelID(engine: EngineID.coreMLStableDiffusion, key: "sd-model")]
        )

        #expect(outcome == .migrated(ModelID(engine: .coreMLStableDiffusion, key: "sd-model")))
    }

    @Test("An existing engine-qualified selection is never overwritten")
    func alreadyMigratedIsLeftAlone() {
        let existing = ModelID(engine: coreML, key: "something-else")

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL("klein-model"),
            existing: existing,
            discovered: [ModelID(engine: .iris, key: "klein-model")]
        )

        // Idempotency is what makes this safe to call on every model load, and
        // what stops a stale legacy value from clobbering a later choice.
        #expect(outcome == .alreadyMigrated)
    }
}

/// Applying the decision: the migrated id must land in the store, exactly once,
/// and be visible through the same property the app reads.
@MainActor
struct ConfigStoreMigrationTests {
    let temp: TempDirectory
    let tempDefaults: TempDefaults
    let modelDir: URL

    init() throws {
        temp = try TempDirectory()
        tempDefaults = TempDefaults()
        modelDir = try temp.subdirectory("models")
    }

    private func makeStore() -> ConfigStore {
        ConfigStore(store: tempDefaults.defaults)
    }

    @Test("Migrating writes the engine-qualified selection through the store")
    func migrationWritesSelection() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "sd-model"), forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()
        #expect(store.selectedModel == nil)

        let outcome = store.migrateSelectedModelIfNeeded(
            discovered: [ModelID(engine: .coreMLStableDiffusion, key: "sd-model")])

        #expect(outcome == .migrated(ModelID(engine: .coreMLStableDiffusion, key: "sd-model")))
        #expect(store.selectedModel == ModelID(engine: .coreMLStableDiffusion, key: "sd-model"))
    }

    @Test("The migrated selection is readable by a fresh store over the same defaults")
    func migrationPersists() throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "klein-model"), forKey: ConfigStore.Key.legacyModelId)
        makeStore().migrateSelectedModelIfNeeded(
            discovered: [ModelID(engine: .iris, key: "klein-model")])

        // A relaunch reads the migrated value, not the legacy one.
        #expect(makeStore().selectedModel == ModelID(engine: .iris, key: "klein-model"))
    }

    @Test("Migrating twice does not change the selection the second time")
    func migrationIsIdempotent() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        try makeSDModelFixture(at: modelDir.appending(path: "other-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "sd-model"), forKey: ConfigStore.Key.legacyModelId)
        let discovered = [
            ModelID(engine: .coreMLStableDiffusion, key: "sd-model"),
            ModelID(engine: .coreMLStableDiffusion, key: "other-model"),
        ]
        let store = makeStore()
        store.migrateSelectedModelIfNeeded(discovered: discovered)

        // A choice made after migrating must survive the next call, even though
        // the legacy key is still there naming a different model.
        store.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "other-model")
        let outcome = store.migrateSelectedModelIfNeeded(discovered: discovered)

        #expect(outcome == .alreadyMigrated)
        #expect(store.selectedModel == ModelID(engine: .coreMLStableDiffusion, key: "other-model"))
    }

    @Test("The legacy key is left in place")
    func legacyKeyIsPreserved() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let legacyURL = modelDir.appending(path: "sd-model")
        tempDefaults.defaults.set(legacyURL, forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()

        store.migrateSelectedModelIfNeeded(
            discovered: [ModelID(engine: .coreMLStableDiffusion, key: "sd-model")])

        // Deleting it would buy nothing and make a downgrade more destructive.
        #expect(store.legacyModelId?.lastPathComponent == "sd-model")
    }

    @Test("Configured folders are untouched by migration")
    func foldersAreUntouched() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "sd-model"), forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()
        store.modelDir = modelDir.path(percentEncoded: false)
        store.controlNetDir = "/somewhere/controlnet"
        store.imageDir = "/somewhere/images"

        store.migrateSelectedModelIfNeeded(
            discovered: [ModelID(engine: .coreMLStableDiffusion, key: "sd-model")])

        // The failure mode that would hurt most on upgrade is a user having to
        // re-pick their folders.
        #expect(store.modelDir == modelDir.path(percentEncoded: false))
        #expect(store.controlNetDir == "/somewhere/controlnet")
        #expect(store.imageDir == "/somewhere/images")
    }

    @Test("A model load migrates a legacy selection and restores that model")
    func loadingModelsMigratesAndRestores() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-model"))
        try makeSDModelFixture(at: modelDir.appending(path: "b-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "b-model"), forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()
        store.modelDir = modelDir.path(percentEncoded: false)

        let controller = GenerationController(
            configStore: store,
            modelRepository: ModelRepository(),
            imageRepository: ImageRepository(),
            startsObserving: false
        )
        await controller.loadModels()

        // End to end: a user upgrading keeps the model they had, rather than
        // silently getting the alphabetically first one.
        #expect(controller.currentModel?.name == "b-model")
        #expect(store.selectedModel == ModelID(engine: .coreMLStableDiffusion, key: "b-model"))
    }
}
