//
//  EngineSelectionTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins the combined model picker and what discovery reports per engine.
///
/// `loadModels()` is called directly for the same reason as
/// `ModelSelectionPersistenceTests`: `init` only schedules it.
@MainActor
@Suite(.serialized)
struct ModelPickerTests {
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
        engineRegistry: EngineRegistry = EngineRegistry()
    ) -> GenerationController {
        makeTestGenerationController(
            configStore: configStore,
            engineRegistry: engineRegistry,
            startsObserving: false
        )
    }

    /// Reports itself ready and then fails to list anything — the shape of a folder
    /// that exists but cannot be read, and of a configured server that does not
    /// answer.
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
        static let modelListSource = ModelListSource.modelsFolder
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

    @Test("With nothing persisted, the first model by name is selected")
    func firstModelIsSelected() async throws {
        try makeMixedFolder()
        let controller = makeController()

        await controller.loadModels()

        // Not the first engine in registration order — Iris is registered first,
        // and choosing by that would open a mixed folder on a Klein model.
        #expect(controller.currentModel?.name == "a-coreml")
    }

    @Test("The stable model picker combines every engine's models")
    func combinedPickerShowsEveryModel() async throws {
        try makeMixedFolder()
        let controller = makeController()

        await controller.loadModels()

        #expect(controller.modelPickerItems.map(\.name) == ["a-coreml", "b-klein"])
        #expect(
            controller.modelPickerItems.compactMap(\.id).map(\.engine)
                == [.coreMLStableDiffusion, .iris]
        )
        // Every model is on this Mac, so the picker shows no headers.
        #expect(controller.modelPickerItems.allSatisfy { $0.section == nil })
    }

    @Test("Server models follow this Mac's models under their own header")
    func pickerGroupsModelsBySource() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "m-coreml"))
        let controller = makeController(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(CoreMLStableDiffusionEngine()),
                AnyGenerationEngine(NamedServerEngine(names: ["a-server", "z-server"])),
            ]))

        await controller.loadModels()

        #expect(controller.modelPickerItems.map(\.name) == ["m-coreml", "a-server", "z-server"])
        #expect(
            controller.modelPickerItems.map(\.section)
                == [
                    GenerationController.pickerSectionTitle(.modelsFolder),
                    "Draw Things — studio.local",
                    "Draw Things — studio.local",
                ]
        )

        // With every source's models known, a saved model that has gone falls back
        // to the first model the picker shows, not the first by name.
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "removed")
        await controller.loadModels(from: [.modelsFolder])
        #expect(controller.currentModel?.name == "m-coreml")
    }

    @Test("A server model named like a local one keeps its name under its header")
    func namesCollideOnlyWithinAGroup() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "shared"))
        let controller = makeController(
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(CoreMLStableDiffusionEngine()),
                AnyGenerationEngine(NamedServerEngine(names: ["Shared"])),
            ]))

        await controller.loadModels()

        #expect(controller.modelPickerItems.map(\.name) == ["shared", "Shared"])
    }

    @Test("Only colliding model names include their engine")
    func combinedPickerDisambiguatesCollisions() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)
        try makeSDModelFixture(at: modelDir.appending(path: "unique"))
        let controller = makeController()

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

    @Test("Choosing a model from another engine applies that model's constraints")
    func choosingAModelAppliesItsConstraints() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()

        controller.setStartingImage(image: makeCGImage(), filename: "start.png")
        let item = try #require(controller.modelPickerItems.first { $0.name == "b-klein" })
        let iris = try #require(item.id)
        controller.currentModelId = iris

        #expect(controller.currentConstraints.inputImages.isSupported)
        #expect(!controller.currentConstraints.startingImage.isSupported)
        // The picture stays the starting image it was chosen as. Klein does not
        // read one, so it is simply inactive here — what the two roles do when the
        // model changes is `GenerationRequestBuilderTests`' subject, not this
        // suite's.
        #expect(controller.startingImage?.name == "start.png")
        #expect(controller.inputImages.isEmpty)
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

        controller.currentModelId = nil

        #expect(controller.controlNet.isEmpty)
        #expect(controller.currentControlNets.isEmpty)
    }

    @Test("The engine list includes every registered engine")
    func allEnginesAreListed() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()
        await controller.loadModels()

        // Exact, so an engine added to the shipped registry is a deliberate change.
        #expect(
            controller.engines.map(\.id) == [.iris, .coreMLStableDiffusion, .drawThings])
        #expect(controller.engineAvailability[.iris] == .ready)
        #expect(controller.engineAvailability[.coreMLStableDiffusion] == .ready)
        #expect(controller.hasModels(.coreMLStableDiffusion))
        #expect(!controller.hasModels(.iris))
    }

    /// The picker distinguishes "there are none" from "we could not look". A
    /// folder that exists but cannot be read answers `.ready` from `availability`
    /// and then fails in discovery, which must not read as "No models found".
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

    @Test("Local models name their family and folder, and recommend nothing")
    func localModelDetails() async throws {
        try makeMixedFolder()
        let controller = makeController()
        await controller.loadModels()

        for name in ["a-coreml", "b-klein"] {
            let item = try #require(controller.modelPickerItems.first { $0.name == name })
            controller.currentModelId = item.id
            let model = try #require(controller.currentModel)
            #expect(model.familyName != nil)
            guard case .directory(let url) = model.location else {
                Issue.record("\(name) should be in a directory")
                continue
            }
            #expect(url.lastPathComponent == name)

            configStore.steps = 30
            configStore.guidanceScale = 7
            controller.applyRecommendedSettings()
            #expect(configStore.steps == 30)
            #expect(configStore.guidanceScale == 7)
            #expect(controller.settingsDifferingFromRecommendations.isEmpty)
        }
    }

    @Test("Recommended settings apply, and are flagged, only for what the model recommends")
    func applyingRecommendedSettings() async throws {
        let controller = makeController(
            engineRegistry: EngineRegistry(engines: [AnyGenerationEngine(RecommendingEngine())]))
        await controller.loadModels()

        controller.currentModelId = RecommendingEngine.withGuidance
        configStore.steps = 30
        configStore.guidanceScale = 7
        #expect(controller.settingsDifferingFromRecommendations == [.steps, .guidanceScale])
        controller.applyRecommendedSetting(.guidanceScale)
        #expect(configStore.steps == 30)
        #expect(configStore.guidanceScale == 3.5)
        #expect(controller.settingsDifferingFromRecommendations == [.steps])
        controller.applyRecommendedSettings()
        #expect(configStore.steps == 8)
        #expect(configStore.guidanceScale == 3.5)
        #expect(controller.settingsDifferingFromRecommendations.isEmpty)

        controller.currentModelId = RecommendingEngine.stepsOnly
        configStore.guidanceScale = 7
        #expect(controller.settingsDifferingFromRecommendations == [.steps])
        controller.applyRecommendedSettings()
        #expect(configStore.steps == 4)
        #expect(configStore.guidanceScale == 7)
        #expect(controller.settingsDifferingFromRecommendations.isEmpty)
    }
}

/// Lists one model that recommends steps and guidance, and one that recommends
/// steps alone, as a distilled server model does.
private struct RecommendingEngine: GenerationEngineDescriptor {
    struct Model: EngineModel {
        let id: ModelID
        let name: String
        let recommendedSteps: Int?
        let recommendedGuidanceScale: Double?
        var constraints: OptionConstraints { .unconstrained }
        var metadataFields: Set<MetadataField> { [.prompt] }
        var tokenizerModelDir: URL? { nil }
    }
    struct Payload: Sendable {}
    struct NotRun: Error {}

    static let id = EngineID(rawValue: "recommending")
    static let modelListSource = ModelListSource.connection
    static let withGuidance = ModelID(engine: id, key: "with-guidance")
    static let stepsOnly = ModelID(engine: id, key: "steps-only")
    var displayName: String { "Recommending" }

    func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
        [
            Model(
                id: Self.withGuidance, name: "with-guidance",
                recommendedSteps: 8, recommendedGuidanceScale: 3.5),
            Model(
                id: Self.stepsOnly, name: "steps-only",
                recommendedSteps: 4, recommendedGuidanceScale: nil),
        ]
    }

    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
        throw NotRun()
    }

    func makeRuntime() -> any GenerationEngineRuntime { fatalError("never runs") }
}

/// A server whose models have the given names.
private struct NamedServerEngine: GenerationEngineDescriptor {
    struct Model: EngineModel {
        let id: ModelID
        let name: String
        var constraints: OptionConstraints { .unconstrained }
        var metadataFields: Set<MetadataField> { [.prompt] }
        var tokenizerModelDir: URL? { nil }
        var location: ModelLocation? { .server(name: "studio.local", file: name) }
    }
    struct Payload: Sendable {}
    struct NotRun: Error {}

    static let id = EngineID(rawValue: "named-server")
    static let modelListSource = ModelListSource.connection
    let names: [String]
    var displayName: String { "Named Server" }

    func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
        names.map { Model(id: ModelID(engine: Self.id, key: $0), name: $0) }
    }

    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
        throw NotRun()
    }

    func makeRuntime() -> any GenerationEngineRuntime { fatalError("never runs") }
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
    static let modelListSource = ModelListSource.modelsFolder
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
                .iris, .coreMLStableDiffusion, .drawThings,
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
    static let modelListSource = ModelListSource.modelsFolder
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

        // The newer pass finishes *completely* before the older one is released.
        // Awaiting `second.value` here rather than at the end fixes that order:
        // releasing a gate only schedules the waiting continuation, so releasing
        // both and then awaiting would leave the order they apply in unspecified.
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

/// A server engine for the tests below: its models come from a connection, and
/// the test decides whether the server answers.
private actor ServerState {
    var isReachable = true
    private(set) var discoveryCount = 0

    func setReachable(_ reachable: Bool) { isReachable = reachable }

    func discover() throws -> Bool {
        discoveryCount += 1
        return isReachable
    }
}

private struct ServerEngine: GenerationEngineDescriptor {
    struct Model: EngineModel {
        let id: ModelID
        let name: String
        var constraints: OptionConstraints { .unconstrained }
        var metadataFields: Set<MetadataField> { [.prompt] }
        var tokenizerModelDir: URL? { nil }
    }
    struct Payload: Sendable {}
    struct NotRun: Error {}
    struct Unreachable: Error {}

    static let id = EngineID(rawValue: "server")
    static let modelListSource = ModelListSource.connection
    static let modelID = ModelID(engine: id, key: "server-model")
    let state: ServerState
    /// Holds discovery until released, when set.
    var sequencer: LoadSequencer?
    var displayName: String { "Server" }

    func availability(_ settings: EngineSettings) async -> EngineAvailability { .ready }

    func discoverModels(_ context: ModelDiscoveryContext) async throws -> [Model] {
        if let sequencer {
            let call = await sequencer.begin()
            await sequencer.waitForRelease(call)
        }
        guard try await state.discover() else { throw Unreachable() }
        return [Model(id: Self.modelID, name: "server-model")]
    }

    func plan(draft: GenerationDraft, model: Model) throws -> GenerationPlan<Payload> {
        throw NotRun()
    }

    func makeRuntime() -> any GenerationEngineRuntime { fatalError("never runs") }
}

/// Pins that the models folder and a server connection refresh separately: a
/// folder change never asks the server, a slow server does not hold back local
/// models, and selection never waits for a server.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct SourceRefreshTests {
    let temp: TempDirectory
    let modelDir: URL
    let tempDefaults: TempDefaults
    let configStore: ConfigStore
    let localID = ModelID(engine: .coreMLStableDiffusion, key: "a-coreml")

    init() throws {
        temp = try TempDirectory()
        modelDir = try temp.subdirectory("models")
        tempDefaults = TempDefaults()
        configStore = ConfigStore(store: tempDefaults.defaults)
        configStore.modelDir = modelDir.path(percentEncoded: false)
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
    }

    private func makeController(_ server: ServerEngine) -> GenerationController {
        makeTestGenerationController(
            configStore: configStore,
            engineRegistry: EngineRegistry(engines: [
                AnyGenerationEngine(CoreMLStableDiffusionEngine()),
                AnyGenerationEngine(server),
            ]),
            startsObserving: false
        )
    }

    @Test("A models-folder refresh does not ask a connection engine")
    func folderRefreshSkipsConnections() async throws {
        let state = ServerState()
        let registry = EngineRegistry(engines: [
            AnyGenerationEngine(CoreMLStableDiffusionEngine()),
            AnyGenerationEngine(ServerEngine(state: state)),
        ])
        let settings = EngineSettings(modelDirectory: modelDir, controlNetDirectory: modelDir)

        let refresh = await registry.refresh(settings: settings, sources: [.modelsFolder])

        #expect(refresh.discoveries.map(\.engine) == [.coreMLStableDiffusion])
        #expect(refresh.availability[ServerEngine.id] == nil)
        #expect(await state.discoveryCount == 0)
    }

    @Test("Local models are shown while a server is still loading")
    func localModelsDoNotWaitForTheServer() async throws {
        let sequencer = LoadSequencer()
        let controller = makeController(ServerEngine(state: ServerState(), sequencer: sequencer))

        let load = Task { await controller.loadModels() }
        await sequencer.waitUntilStarted(1)
        while controller.models.isEmpty { await Task.yield() }

        #expect(controller.models.map(\.id) == [localID])
        #expect(controller.currentModelId == localID)

        await sequencer.release(1)
        _ = await load.value
        #expect(controller.models.map(\.id) == [localID, ServerEngine.modelID])
    }

    @Test("A saved server model is not waited for: the first available model is selected")
    func savedServerModelIsNotWaitedFor() async throws {
        configStore.selectedModel = ServerEngine.modelID
        let sequencer = LoadSequencer()
        let controller = makeController(ServerEngine(state: ServerState(), sequencer: sequencer))

        let load = Task { await controller.loadModels() }
        await sequencer.waitUntilStarted(1)
        while controller.models.isEmpty { await Task.yield() }

        #expect(controller.currentModelId == localID)
        #expect(configStore.selectedModel == localID)
        #expect(controller.discoveryMessage == nil)

        await sequencer.release(1)
        _ = await load.value
        #expect(controller.currentModelId == localID)
    }

    @Test("A saved server model falls back once its server fails to answer")
    func unreachableServerAtLaunchFallsBack() async throws {
        configStore.selectedModel = ServerEngine.modelID
        let state = ServerState()
        await state.setReachable(false)
        let controller = makeController(ServerEngine(state: state))

        await controller.loadModels()

        #expect(controller.currentModelId == localID)
        #expect(configStore.selectedModel == localID)
    }

    @Test("A models-folder refresh keeps the server's models and the selected server model")
    func folderRefreshKeepsServerModels() async throws {
        let state = ServerState()
        let controller = makeController(ServerEngine(state: state))
        await controller.loadModels()
        controller.currentModelId = ServerEngine.modelID

        await controller.loadModels(from: [.modelsFolder])

        #expect(controller.models.map(\.id) == [localID, ServerEngine.modelID])
        #expect(controller.currentModelId == ServerEngine.modelID)
        #expect(await state.discoveryCount == 1)
    }

    @Test("Reconnecting to an unreachable server falls back and saves the fallback")
    func failedReconnectFallsBack() async throws {
        let state = ServerState()
        let controller = makeController(ServerEngine(state: state))
        await controller.loadModels()
        controller.currentModelId = ServerEngine.modelID

        await state.setReachable(false)
        await controller.loadModels(from: [.connection])

        #expect(controller.models.map(\.id) == [localID])
        #expect(controller.currentModelId == localID)
        #expect(configStore.selectedModel == localID)
    }
}
