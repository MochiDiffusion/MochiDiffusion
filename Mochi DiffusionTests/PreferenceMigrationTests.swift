//
//  PreferenceMigrationTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

@testable import Mochi_Diffusion

/// §7 of `Multi-Engine-Design.md` calls the selected-model migration the
/// highest-risk detail in the plan: get it wrong and every existing user loses
/// the model they had selected, or worse, their configured folders.
///
/// The decision is a pure function, so most of this needs no `UserDefaults` at
/// all; `ConfigStoreMigrationTests` covers applying it.
struct PreferenceMigrationTests {
    let temp: TempDirectory
    let modelDir: URL

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
    }

    // MARK: - Classification

    @Test("A legacy selection of a Core ML model migrates to the Core ML engine")
    func migratesCoreMLSelection() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: modelDir.appending(path: "sd-model"),
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(
            outcome == .migrated(ModelID(engine: .coreMLStableDiffusion, key: "sd-model"))
        )
    }

    @Test("A legacy selection of a Klein model migrates to the Iris engine")
    func migratesKleinSelection() throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: modelDir.appending(path: "klein-model"),
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(outcome == .migrated(ModelID(engine: .iris, key: "klein-model")))
    }

    /// The frozen classifier has to reproduce `ModelRepository.load`'s sniff
    /// order, because that order is what decided which kind of model the user was
    /// actually looking at when the preference was written. Klein was tested
    /// first, so a directory satisfying both migrates to Iris.
    @Test("A directory both engines recognise migrates the way the old app read it")
    func ambiguousDirectoryFollowsTheOldSniffOrder() throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: ambiguous,
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(outcome == .migrated(ModelID(engine: .iris, key: "ambiguous")))
    }

    // MARK: - Paths that cannot be migrated

    @Test("A legacy selection that no longer exists is left unmigrated")
    func missingDirectoryIsUnresolvable() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: modelDir.appending(path: "deleted-model"),
            existing: nil,
            modelDirectory: modelDir
        )

        // Not an error: the app already falls back to the first model for a
        // selection that does not resolve.
        #expect(outcome == .unresolvable)
    }

    @Test("A legacy selection naming a directory no engine recognises is left unmigrated")
    func unrecognisedDirectoryIsUnresolvable() throws {
        try writeFile("{}", to: modelDir.appending(components: "not-a-model", "readme.txt"))

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: modelDir.appending(path: "not-a-model"),
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(outcome == .unresolvable)
    }

    @Test("No legacy selection is nothing to migrate")
    func noLegacySelection() {
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: nil,
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(outcome == .nothingToMigrate)
    }

    // MARK: - Path spelling and idempotency

    /// The legacy value is an absolute URL written by a previous launch, and may
    /// be spelled differently from the root configured now — the mismatch that
    /// motivated key-based identity. Only the directory name is taken from it.
    @Test(
        "The legacy URL's spelling does not affect the migrated key",
        arguments: [true, false]
    )
    func spellingDoesNotAffectTheKey(resolved: Bool) throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let path = modelDir.appending(path: "sd-model").path(percentEncoded: false)
        let legacyURL = URL(fileURLWithPath: resolved ? "/private" + path : path)

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: legacyURL,
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(
            outcome == .migrated(ModelID(engine: .coreMLStableDiffusion, key: "sd-model"))
        )
    }

    @Test("An existing engine-qualified selection is never overwritten")
    func alreadyMigratedIsLeftAlone() throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        let existing = ModelID(engine: .coreMLStableDiffusion, key: "something-else")

        let outcome = PreferenceMigration.selectedModel(
            legacyURL: modelDir.appending(path: "klein-model"),
            existing: existing,
            modelDirectory: modelDir
        )

        // Idempotency is what makes this safe to call on every model load, and
        // what stops a stale legacy value from clobbering a later choice.
        #expect(outcome == .alreadyMigrated)
    }

    @Test("A legacy URL that is not a direct child of the models root is rejected")
    func legacyURLOutsideRootIsRejected() throws {
        // A key is a single path component, so nothing derived from a legacy URL
        // can point outside the configured models directory.
        let outcome = PreferenceMigration.selectedModel(
            legacyURL: URL(fileURLWithPath: "/"),
            existing: nil,
            modelDirectory: modelDir
        )

        #expect(outcome == .unresolvable)
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

        let outcome = store.migrateSelectedModelIfNeeded(modelDirectory: modelDir)

        #expect(outcome == .migrated(ModelID(engine: .coreMLStableDiffusion, key: "sd-model")))
        #expect(store.selectedModel == ModelID(engine: .coreMLStableDiffusion, key: "sd-model"))
    }

    @Test("The migrated selection is readable by a fresh store over the same defaults")
    func migrationPersists() throws {
        try makeKleinModelFixture(at: modelDir.appending(path: "klein-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "klein-model"), forKey: ConfigStore.Key.legacyModelId)
        makeStore().migrateSelectedModelIfNeeded(modelDirectory: modelDir)

        // A relaunch reads the migrated value, not the legacy one.
        #expect(makeStore().selectedModel == ModelID(engine: .iris, key: "klein-model"))
    }

    @Test("Migrating twice does not change the selection the second time")
    func migrationIsIdempotent() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        try makeSDModelFixture(at: modelDir.appending(path: "other-model"))
        tempDefaults.defaults.set(
            modelDir.appending(path: "sd-model"), forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()
        store.migrateSelectedModelIfNeeded(modelDirectory: modelDir)

        // A choice made after migrating must survive the next call, even though
        // the legacy key is still there naming a different model.
        store.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "other-model")
        let outcome = store.migrateSelectedModelIfNeeded(modelDirectory: modelDir)

        #expect(outcome == .alreadyMigrated)
        #expect(store.selectedModel == ModelID(engine: .coreMLStableDiffusion, key: "other-model"))
    }

    @Test("The legacy key is left in place")
    func legacyKeyIsPreserved() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "sd-model"))
        let legacyURL = modelDir.appending(path: "sd-model")
        tempDefaults.defaults.set(legacyURL, forKey: ConfigStore.Key.legacyModelId)
        let store = makeStore()

        store.migrateSelectedModelIfNeeded(modelDirectory: modelDir)

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

        store.migrateSelectedModelIfNeeded(modelDirectory: modelDir)

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
