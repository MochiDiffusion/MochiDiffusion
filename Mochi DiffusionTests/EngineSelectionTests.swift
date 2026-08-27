//
//  EngineSelectionTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the per-engine selection store: what it reads, what it refuses, and that
/// one engine's selection cannot leak into another's.
@MainActor
struct EngineSettingsStoreTests {
    let tempDefaults = TempDefaults()

    private func makeStore() -> EngineSettingsStore {
        EngineSettingsStore(
            store: tempDefaults.defaults,
            engines: [.iris, .coreMLStableDiffusion]
        )
    }

    @Test("A selected engine round-trips through a fresh store")
    func selectedEngineRoundTrips() {
        let store = makeStore()
        store.selectedEngine = .iris

        #expect(makeStore().selectedEngine == .iris)
    }

    @Test("Clearing the selected engine removes the key rather than blanking it")
    func clearingSelectedEngine() {
        let store = makeStore()
        store.selectedEngine = .iris
        store.selectedEngine = nil

        #expect(makeStore().selectedEngine == nil)
        #expect(tempDefaults.defaults.string(forKey: EngineSettingsStore.Key.selectedEngine) == nil)
    }

    @Test("Each engine remembers its own model independently")
    func selectionsAreIndependentPerEngine() {
        let store = makeStore()
        let klein = ModelID(engine: .iris, key: "klein")
        let coreML = ModelID(engine: .coreMLStableDiffusion, key: "sd15")

        store.setSelectedModel(klein, for: .iris)
        store.setSelectedModel(coreML, for: .coreMLStableDiffusion)

        let reloaded = makeStore()
        #expect(reloaded.selectedModel(for: .iris) == klein)
        #expect(reloaded.selectedModel(for: .coreMLStableDiffusion) == coreML)
    }

    /// Filing one engine's model under another would let a selection resolve to a
    /// model the picker never offered for that engine.
    @Test("A model belonging to another engine is not filed")
    func mismatchedModelIsRejected() {
        let store = makeStore()
        store.setSelectedModel(ModelID(engine: .iris, key: "klein"), for: .coreMLStableDiffusion)

        #expect(store.selectedModel(for: .coreMLStableDiffusion) == nil)
    }

    /// The same check on the way in, for a key hand-edited or left by a bug.
    @Test("A persisted key whose engine disagrees with its slot is ignored")
    func mismatchedPersistedKeyIsIgnored() {
        tempDefaults.defaults.set(
            ModelID(engine: .iris, key: "klein").persistedValue,
            forKey: EngineSettingsStore.Key.selectedModel(.coreMLStableDiffusion)
        )

        #expect(makeStore().selectedModel(for: .coreMLStableDiffusion) == nil)
    }

    @Test("A malformed persisted key is ignored rather than trapping")
    func malformedPersistedKeyIsIgnored() {
        for value in ["", ":", "iris:", ":klein", "no-separator"] {
            tempDefaults.defaults.set(
                value, forKey: EngineSettingsStore.Key.selectedModel(.iris))
            #expect(makeStore().selectedModel(for: .iris) == nil)
        }
    }

    @Test("Only the engines asked for are loaded")
    func unregisteredEngineIsNotLoaded() {
        let ghost = EngineID(rawValue: "ghost")
        tempDefaults.defaults.set(
            ModelID(engine: ghost, key: "model").persistedValue,
            forKey: EngineSettingsStore.Key.selectedModel(ghost)
        )

        #expect(makeStore().selectedModel(for: ghost) == nil)
    }

    @Test("Clearing a model selection removes its key")
    func clearingModelSelection() {
        let store = makeStore()
        store.setSelectedModel(ModelID(engine: .iris, key: "klein"), for: .iris)
        store.setSelectedModel(nil, for: .iris)

        #expect(makeStore().selectedModel(for: .iris) == nil)
    }
}

/// Pins the Phase 2 → Phase 5 selection migration as a pure decision.
struct EngineSelectionMigrationTests {
    private let klein = ModelID(engine: .iris, key: "klein")

    @Test("An existing engine selection means the migration has already run")
    func alreadyMigrated() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            existingEngine: .coreMLStableDiffusion,
            discovered: [klein]
        )

        #expect(outcome == .alreadyMigrated)
    }

    @Test("No previous selection is nothing to migrate")
    func nothingToMigrate() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: nil,
            existingEngine: nil,
            discovered: [klein]
        )

        #expect(outcome == .nothingToMigrate)
    }

    @Test("A previous selection that discovery found becomes the engine selection")
    func migratesDiscoveredSelection() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            existingEngine: nil,
            discovered: [klein, ModelID(engine: .coreMLStableDiffusion, key: "sd15")]
        )

        #expect(outcome == .migrated(klein))
    }

    /// The case that would otherwise strand an upgrading user: recording an engine
    /// that has no models, which the controller then keeps rather than falling back
    /// from.
    @Test("A previous selection discovery did not find records no engine")
    func doesNotMigrateUnresolvableSelection() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            existingEngine: nil,
            discovered: [ModelID(engine: .coreMLStableDiffusion, key: "sd15")]
        )

        #expect(outcome == .unresolvable)
    }

    @Test("An unresolvable selection is retried rather than remembered")
    func unresolvableIsRetried() {
        // Nothing was written, so a later pass with the model present migrates it.
        let later = EngineSelectionMigration.selection(
            previousSelection: klein,
            existingEngine: nil,
            discovered: [klein]
        )

        #expect(later == .migrated(klein))
    }
}

/// Pins what the engine picker does to the model selection.
///
/// `loadModels()` is called directly for the same reason as
/// `ModelSelectionPersistenceTests`: `init` only schedules it.
@MainActor
@Suite(.serialized)
struct EnginePickerTests {
    let temp: TempDirectory
    let tempDefaults: TempDefaults
    let configStore: ConfigStore
    let modelDir: URL
    let controlNetDir: URL

    init() throws {
        temp = try TempDirectory()
        tempDefaults = TempDefaults()
        configStore = ConfigStore(store: tempDefaults.defaults)
        modelDir = try temp.subdirectory("models")
        controlNetDir = try temp.subdirectory("controlnet")
        configStore.modelDir = modelDir.path(percentEncoded: false)
        configStore.controlNetDir = controlNetDir.path(percentEncoded: false)
    }

    private func makeController() -> GenerationController {
        GenerationController(configStore: configStore, startsObserving: false)
    }

    /// One Core ML model and one Klein model, named so the Core ML one sorts first.
    private func makeMixedFolder() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
    }

    @Test("With nothing persisted, the first model's engine is selected")
    func firstModelDecidesTheEngine() async throws {
        try makeMixedFolder()
        let controller = makeController()

        await controller.loadModels()

        // Not the first engine in registration order — Iris is registered first,
        // and choosing by that would open a mixed folder on a Klein model.
        #expect(controller.selectedEngine == .coreMLStableDiffusion)
        #expect(controller.currentModel?.name == "a-coreml")
    }

    @Test("The model picker shows only the selected engine's models")
    func visibleModelsAreScopedToTheEngine() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.count == 2)
        #expect(controller.visibleModels.map(\.name) == ["a-coreml"])

        controller.selectEngine(.iris)

        #expect(controller.visibleModels.map(\.name) == ["b-klein"])
    }

    @Test("Switching engine selects that engine's first model")
    func switchingEngineSelectsItsModel() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()

        controller.selectEngine(.iris)

        #expect(controller.selectedEngine == .iris)
        #expect(controller.currentModel?.name == "b-klein")
    }

    /// The point of per-engine selections: coming back to an engine returns the
    /// model you left it on, not its first.
    @Test("Each engine remembers the model it was last using")
    func engineRemembersItsModel() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeSDModelFixture(at: modelDir.appending(path: "c-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        let controller = makeController()
        await controller.loadModels()

        controller.currentModelId = try #require(
            controller.models.first { $0.name == "c-coreml" }
        ).id
        controller.selectEngine(.iris)
        controller.selectEngine(.coreMLStableDiffusion)

        #expect(controller.currentModel?.name == "c-coreml")
    }

    @Test("A remembered engine and model are restored on the next launch")
    func rememberedSelectionSurvivesRelaunch() async throws {
        try makeMixedFolder()
        let first = makeController()
        await first.loadModels()
        first.selectEngine(.iris)

        let second = makeController()
        await second.loadModels()

        #expect(second.selectedEngine == .iris)
        #expect(second.currentModel?.name == "b-klein")
    }

    /// §8: an engine the user chose stays chosen even when empty, and Generate is
    /// disabled, rather than silently generating with another engine's model.
    @Test("Choosing an engine with no models leaves the selection empty")
    func emptyEngineLeavesSelectionEmpty() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()
        await controller.loadModels()

        controller.selectEngine(.iris)

        #expect(controller.selectedEngine == .iris)
        #expect(controller.currentModelId == nil)
        #expect(controller.visibleModels.isEmpty)
        #expect(controller.hasModels(.iris) == false)
        #expect(controller.hasModels(.coreMLStableDiffusion))
    }

    @Test("An empty engine choice survives a relaunch rather than reverting")
    func emptyEngineChoiceSurvivesRelaunch() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let first = makeController()
        await first.loadModels()
        first.selectEngine(.iris)

        let second = makeController()
        await second.loadModels()

        #expect(second.selectedEngine == .iris)
        #expect(second.currentModelId == nil)
    }

    @Test("Selecting nothing clears the ControlNet options too")
    func emptyEngineClearsControlNets() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "a-controlled"),
            inputSize: CGSize(width: 512, height: 512),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = makeController()
        await controller.loadModels()
        #expect(controller.controlNet == ["canny"])

        controller.selectEngine(.iris)

        #expect(controller.controlNet.isEmpty)
        #expect(controller.currentControlNets.isEmpty)
    }

    @Test("Every registered engine is listed, including the empty one")
    func allEnginesAreListed() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()
        await controller.loadModels()

        #expect(controller.engines.map(\.id) == [.iris, .coreMLStableDiffusion])
        #expect(controller.engineAvailability[.iris] == .ready)
        #expect(controller.engineAvailability[.coreMLStableDiffusion] == .ready)
    }

    @Test("A missing models folder reports both engines as unreachable")
    func missingFolderIsReportedPerEngine() async throws {
        configStore.modelDir = temp.appending("does-not-exist").path(percentEncoded: false)
        let controller = makeController()

        await controller.loadModels()

        for engine in [EngineID.iris, .coreMLStableDiffusion] {
            guard case .unreachable = controller.engineAvailability[engine] else {
                Issue.record("\(engine) should be unreachable")
                continue
            }
        }
    }
}
