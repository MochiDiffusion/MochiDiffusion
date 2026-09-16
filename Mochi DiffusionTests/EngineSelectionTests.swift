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

    /// "Already run" is the selection being in its own engine's slot — the
    /// migration's own result. It used to be "some engine is selected", which
    /// `restoreSelection`'s fallback could set, so a fallback could claim the
    /// migration was finished when it had not started.
    @Test("The selection already being in its slot means the migration has run")
    func alreadyMigrated() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            alreadyInItsSlot: true,
            discovered: [klein]
        )

        #expect(outcome == .alreadyMigrated)
    }

    /// The reported bug, as a decision. A fallback engine having been persisted
    /// must not end the migration: the legacy selection is still owed a slot.
    @Test("Another engine being selected does not end the migration")
    func fallbackEngineDoesNotEndTheMigration() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            alreadyInItsSlot: false,
            discovered: [klein]
        )

        #expect(outcome == .migrated(klein))
    }

    @Test("No previous selection is nothing to migrate")
    func nothingToMigrate() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: nil,
            alreadyInItsSlot: false,
            discovered: [klein]
        )

        #expect(outcome == .nothingToMigrate)
    }

    @Test("A previous selection that discovery found becomes the engine selection")
    func migratesDiscoveredSelection() {
        let outcome = EngineSelectionMigration.selection(
            previousSelection: klein,
            alreadyInItsSlot: false,
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
            alreadyInItsSlot: false,
            discovered: [ModelID(engine: .coreMLStableDiffusion, key: "sd15")]
        )

        #expect(outcome == .unresolvable)
    }

    @Test("An unresolvable selection is retried rather than remembered")
    func unresolvableIsRetried() {
        // Nothing was written, so a later pass with the model present migrates it.
        let later = EngineSelectionMigration.selection(
            previousSelection: klein,
            alreadyInItsSlot: false,
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

    private func makeController(
        engineRegistry: EngineRegistry = EngineRegistry(),
        modelSelectionMode: GenerationController.ModelSelectionMode = .engineScoped
    ) -> GenerationController {
        makeTestGenerationController(
            configStore: configStore,
            engineRegistry: engineRegistry,
            modelSelectionMode: modelSelectionMode,
            startsObserving: false
        )
    }

    /// Reports itself ready and then fails to list anything — the shape of a folder
    /// that exists but cannot be read, and of a hosted engine whose credentials are
    /// accepted but whose request fails.
    private struct ReadyButFailingEngine: GenerationEngineDescriptor {
        struct Model: EngineModel {
            let id: ModelID
            let url: URL
            let name: String
            var constraints: OptionConstraints { .unconstrained }
            var metadataFields: Set<MetadataField> { [.prompt] }
            var tokenizerModelDir: URL? { nil }
        }
        struct Payload: Sendable {}
        struct Failure: Error {}

        static let id = EngineID(rawValue: "ready-but-failing")
        var displayName: String { "Ready But Failing" }

        func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

        func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
            throw Failure()
        }

        func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
            throw Failure()
        }

        func makeRuntime() -> any GenerationEngineRuntime {
            fatalError("never runs")
        }
    }

    /// One Core ML model and one Klein model, named so the Core ML one sorts first.
    private func makeMixedFolder() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
    }

    @Test("With nothing persisted, the first model's engine is selected")
    func firstModelDecidesTheEngine() async throws {
        try makeMixedFolder()
        let controller = makeController(modelSelectionMode: .combined)

        await controller.loadModels()

        // Not the first engine in registration order — Iris is registered first,
        // and choosing by that would open a mixed folder on a Klein model.
        #expect(controller.selectedEngine == .coreMLStableDiffusion)
        #expect(controller.currentModel?.name == "a-coreml")
    }

    @Test("A stale selection for a removed engine falls back to a shipped engine")
    func removedEngineSelectionFallsBack() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        tempDefaults.defaults.set(
            "drawthings", forKey: EngineSettingsStore.Key.selectedEngine)
        let controller = makeController(modelSelectionMode: .combined)

        await controller.loadModels()

        #expect(controller.selectedEngine == .coreMLStableDiffusion)
        #expect(controller.currentModel?.name == "a-coreml")
        #expect(
            tempDefaults.defaults.string(forKey: EngineSettingsStore.Key.selectedEngine)
                == EngineID.coreMLStableDiffusion.rawValue
        )
    }

    @Test("The model picker shows only the selected engine's models")
    func visibleModelsAreScopedToTheEngine() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.count == 2)
        // Scoped to the selected engine, so the Iris model is not among them.
        #expect(controller.visibleModels.map(\.name) == ["a-coreml"])

        controller.selectEngine(.iris)

        #expect(controller.visibleModels.map(\.name) == ["b-klein"])
    }

    @Test("The stable model picker combines every engine's models")
    func combinedPickerShowsEveryModel() async throws {
        try makeMixedFolder()
        let controller = makeController(modelSelectionMode: .combined)

        await controller.loadModels()

        #expect(controller.modelPickerItems.map(\.name) == ["a-coreml", "b-klein"])
        #expect(
            controller.modelPickerItems.compactMap(\.id).map(\.engine)
                == [.coreMLStableDiffusion, .iris]
        )
    }

    @Test("Only colliding model names include their engine")
    func combinedPickerDisambiguatesCollisions() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)
        try makeSDModelFixture(at: modelDir.appending(path: "unique"))
        let controller = makeController(modelSelectionMode: .combined)

        await controller.loadModels()

        #expect(
            controller.modelPickerItems.map(\.name)
                == [
                    "ambiguous — Core ML Stable Diffusion",
                    "ambiguous — Iris",
                    "unique",
                ]
        )
    }

    @Test("Choosing a combined model selects its engine implicitly")
    func combinedPickerSelectsEngineImplicitly() async throws {
        try makeMixedFolder()
        let controller = makeController(modelSelectionMode: .combined)
        await controller.loadModels()

        controller.setStartingImage(image: makeCGImage(), filename: "start.png")
        let item = try #require(controller.modelPickerItems.first { $0.name == "b-klein" })
        let iris = try #require(item.id)
        controller.currentModelId = iris

        #expect(controller.selectedEngine == .iris)
        #expect(controller.currentConstraints.inputImages.isSupported)
        #expect(!controller.currentConstraints.startingImage.isSupported)
        #expect(controller.startingImage == nil)
        #expect(controller.inputImages.map(\.name) == ["start.png"])
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

    @Test("Settings lists exactly the engines included in the release")
    func allEnginesAreListed() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()
        await controller.loadModels()

        // Every registered engine, which is what Settings ▸ Engines lists. Keep
        // this exact so a deferred engine cannot return to the release unnoticed.
        #expect(controller.engines.map(\.id) == [.iris, .coreMLStableDiffusion])
        #expect(controller.engineAvailability[.iris] == .ready)
        #expect(controller.engineAvailability[.coreMLStableDiffusion] == .ready)
        #expect(controller.engineAvailability[.openAI] == nil)

        // Iris is `.ready` because the folder exists, but it has no Klein model in
        // it, so the sidebar offers only Core ML.
        #expect(controller.pickerEngines.map(\.id) == [.coreMLStableDiffusion])
        #expect(controller.isUsable(.coreMLStableDiffusion))
        #expect(!controller.isUsable(.iris))
        #expect(!controller.isUsable(.openAI))
    }

    /// Both halves of "usable" are needed and neither implies the other.
    @Test("A hosted engine becomes usable when a key is entered")
    func hostedEngineBecomesUsableWithAKey() async throws {
        let secrets = InMemorySecretStore()
        let controller = makeController(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(OpenAIImageEngine(secrets: secrets))
            ]))

        await controller.loadModels()
        // A model, but nothing to authenticate with.
        #expect(controller.hasModels(.openAI))
        #expect(!controller.isUsable(.openAI))
        #expect(controller.pickerEngines.isEmpty)

        try secrets.setSecret("sk-test", for: OpenAIImageEngine.secretAccount)
        await controller.loadModels()

        #expect(controller.isUsable(.openAI))
        #expect(controller.pickerEngines.map(\.id) == [.openAI])
    }

    /// The rule that keeps a selection from pointing at something absent from its
    /// own picker. `restoreSelection` keeps a chosen engine whose models have gone
    /// so the picker can say why, and hiding it would take the explanation too.
    @Test("The selected engine stays listed after its models disappear")
    func selectedEngineStaysListedWhenEmptied() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()
        controller.selectEngine(.iris)
        #expect(controller.pickerEngines.map(\.id).contains(.iris))

        try FileManager.default.removeItem(
            at: modelDir.appending(path: "b-klein"))
        await controller.loadModels()

        #expect(!controller.isUsable(.iris))
        #expect(controller.selectedEngine == .iris)
        // Registration order, which is presentation order and nothing else.
        #expect(controller.pickerEngines.map(\.id) == [.iris, .coreMLStableDiffusion])
    }

    /// The picker distinguishes "there are none" from "we could not look". Before
    /// this was merged in, a folder that existed but could not be read answered
    /// `.ready` from `availability`, failed in discovery, and was reported as
    /// "No models found" — sending the user after missing models when the folder
    /// was the problem.
    @Test("A discovery failure is reported as unreachable, not as an empty engine")
    func discoveryFailureIsNotReportedAsEmpty() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(CoreMLStableDiffusionEngine()),
                AnyGenerationEngine(ReadyButFailingEngine()),
            ])
        )

        await controller.loadModels()

        #expect(
            controller.engineAvailability[ReadyButFailingEngine.id]
                == .unreachable("Models could not be read")
        )
        // The engine that worked is unaffected.
        #expect(controller.engineAvailability[.coreMLStableDiffusion] == .ready)
        #expect(controller.models.map(\.name) == ["a-coreml"])
    }

    /// An engine that is genuinely empty still reads as ready, so the two cases stay
    /// distinguishable in both directions.
    @Test("An engine that simply has no models stays ready")
    func emptyEngineStaysReady() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()

        await controller.loadModels()

        #expect(controller.engineAvailability[.iris] == .ready)
        #expect(controller.hasModels(.iris) == false)
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

/// Records how many engines were inside discovery at once, so concurrency is
/// asserted rather than assumed.
private actor ConcurrencyProbe {
    private(set) var peak = 0
    private(set) var started = 0
    private var inside = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        inside += 1
        started += 1
        peak = max(peak, inside)
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }

    func leave() {
        inside -= 1
    }

    /// Suspends until `count` engines have entered, so the probe does not have to
    /// guess how long to hold them.
    func waitUntilStarted(_ count: Int) async {
        while started < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}

/// Enters the probe, waits for every engine to arrive, then returns. Serial
/// discovery would deadlock here rather than merely be slow, so the assertion is
/// unambiguous.
private struct ProbedEngine: GenerationEngineDescriptor {
    struct Model: EngineModel {
        let id: ModelID
        let url: URL
        let name: String
        var constraints: OptionConstraints { .unconstrained }
        var metadataFields: Set<MetadataField> { [.prompt] }
        var tokenizerModelDir: URL? { nil }
    }
    struct Payload: Sendable {}
    struct NotRun: Error {}

    let engineID: EngineID
    let probe: ConcurrencyProbe
    let expected: Int

    static var id: EngineID { EngineID(rawValue: "probed") }
    var displayName: String { engineID.rawValue }

    func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
        await probe.enter()
        await probe.waitUntilStarted(expected)
        await probe.leave()
        return [
            Model(
                id: ModelID(engine: engineID, key: "model"),
                url: URL(fileURLWithPath: "/dev/null"),
                name: engineID.rawValue
            )
        ]
    }

    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
        throw NotRun()
    }

    func makeRuntime() -> any GenerationEngineRuntime { fatalError("never runs") }
}

/// Pins that one refresh is one consistent snapshot, gathered concurrently.
struct EngineRefreshTests {
    let temp: TempDirectory
    let modelDir: URL

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
    }

    private var settings: EngineSettings {
        EngineSettings(modelDirectory: modelDir, controlNetDirectory: modelDir)
    }

    /// Serial discovery would hang instead of failing an assertion: each engine
    /// waits for the other to arrive. A one-minute limit turns that into a failure.
    @Test("Engines are asked concurrently, not one after another", .timeLimit(.minutes(1)))
    func enginesAreAskedConcurrently() async throws {
        let probe = ConcurrencyProbe()
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(
                ProbedEngine(engineID: EngineID(rawValue: "a"), probe: probe, expected: 2)),
            AnyGenerationEngine(
                ProbedEngine(engineID: EngineID(rawValue: "b"), probe: probe, expected: 2)),
        ])

        let refresh = await registry.refresh(settings: settings)

        #expect(await probe.peak == 2)
        #expect(refresh.models.count == 2)
    }

    /// Registration order is fixed in code, and a task group does not preserve it,
    /// so the refresh has to restore it.
    @Test("Results come back in registration order however they complete")
    func resultsAreInRegistrationOrder() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "z-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "a-klein"))

        let refresh = await EngineRegistry().refresh(settings: settings)

        #expect(
            refresh.discoveries.map(\.engine) == [
                .iris, .coreMLStableDiffusion,
            ])
        // Sorted by name across engines, independent of completion order.
        #expect(
            refresh.models.map(\.name) == ["a-klein", "z-coreml"])
    }

    @Test("Availability and models arrive from the same pass")
    func availabilityAndModelsAreOneSnapshot() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))

        let refresh = await EngineRegistry().refresh(settings: settings)

        #expect(refresh.availability[.coreMLStableDiffusion] == .ready)
        #expect(refresh.availability[.iris] == .ready)
        #expect(refresh.models.map(\.name) == ["a-coreml"])
        #expect(refresh.failures.isEmpty)
    }
}

/// Lets a test decide the order two discovery passes finish in.
private actor LoadSequencer {
    private var startedCalls = 0
    private var released: Set<Int> = []
    private var releaseWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    /// Claims the next call number and reports that it has started.
    func begin() -> Int {
        startedCalls += 1
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters = []
        return startedCalls
    }

    func waitForRelease(_ call: Int) async {
        if released.contains(call) { return }
        await withCheckedContinuation { releaseWaiters[call, default: []].append($0) }
    }

    func release(_ call: Int) {
        released.insert(call)
        for waiter in releaseWaiters[call] ?? [] {
            waiter.resume()
        }
        releaseWaiters[call] = nil
    }

    func waitUntilStarted(_ count: Int) async {
        while startedCalls < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }
}

/// Names its model after the discovery pass that found it, and does not finish
/// until the test says so, so "which pass won" is observable.
private struct GatedEngine: GenerationEngineDescriptor {
    struct Model: EngineModel {
        let id: ModelID
        let url: URL
        let name: String
        var constraints: OptionConstraints { .unconstrained }
        var metadataFields: Set<MetadataField> { [.prompt] }
        var tokenizerModelDir: URL? { nil }
    }
    struct Payload: Sendable {}
    struct NotRun: Error {}

    static let id = EngineID(rawValue: "gated")
    let sequencer: LoadSequencer
    var displayName: String { "Gated" }

    func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
        let call = await sequencer.begin()
        await sequencer.waitForRelease(call)
        return [
            Model(
                id: ModelID(engine: Self.id, key: "call-\(call)"),
                url: URL(fileURLWithPath: "/dev/null"),
                name: "call-\(call)"
            )
        ]
    }

    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
        throw NotRun()
    }

    func makeRuntime() -> any GenerationEngineRuntime { fatalError("never runs") }
}

/// Pins that a discovery pass which finishes late does not overwrite a newer one,
/// and that a shut-down controller stops applying results.
///
/// `loadModels()` is started by the initial load, two folder monitors and two
/// debounced settings paths. `@MainActor` serialises the mutations without
/// preventing reentrancy across the await in the middle, so ordering is a real
/// hazard rather than a theoretical one.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct RefreshOrderingTests {
    let temp: TempDirectory
    let tempDefaults: TempDefaults
    let configStore: ConfigStore

    init() throws {
        temp = try TempDirectory()
        tempDefaults = TempDefaults()
        configStore = ConfigStore(store: tempDefaults.defaults)
        configStore.modelDir = try temp.subdirectory("models").path(percentEncoded: false)
    }

    private func makeController(_ registry: EngineRegistry) -> GenerationController {
        makeTestGenerationController(
            configStore: configStore,
            engineRegistry: registry,
            startsObserving: false
        )
    }

    @Test("A pass that finishes after a newer one discards itself")
    func supersededPassIsDiscarded() async throws {
        let sequencer = LoadSequencer()
        let controller = makeController(
            EngineRegistry(engines: [AnyGenerationEngine(GatedEngine(sequencer: sequencer))])
        )

        let first = Task { await controller.loadModels() }
        await sequencer.waitUntilStarted(1)
        let second = Task { await controller.loadModels() }
        await sequencer.waitUntilStarted(2)

        // The newer pass is allowed to finish *completely* before the older one is
        // released — the order that used to leave the older pass's models on screen.
        //
        // Awaiting `second.value` here rather than at the end is what makes this a
        // pin. Releasing a gate only schedules the waiting continuation, so
        // releasing both and then awaiting leaves the order they apply in
        // unspecified: without the epoch guard the test would pass whenever the
        // older pass happened to run first.
        await sequencer.release(2)
        _ = await second.value
        #expect(controller.models.map(\.name) == ["call-2"])

        await sequencer.release(1)
        _ = await first.value

        #expect(controller.models.map(\.name) == ["call-2"])
    }

    @Test("A refresh already in flight applies nothing after shutdown")
    func shutdownStopsAnInFlightRefresh() async throws {
        let sequencer = LoadSequencer()
        let controller = makeController(
            EngineRegistry(engines: [AnyGenerationEngine(GatedEngine(sequencer: sequencer))])
        )

        let load = Task { await controller.loadModels() }
        await sequencer.waitUntilStarted(1)
        controller.shutdown()
        await sequencer.release(1)
        _ = await load.value

        #expect(controller.models.isEmpty)
        #expect(controller.currentModelId == nil)
    }
}
