//
//  ModelSelectionPersistenceTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Pins how the selected model is restored across launches, and what happens when
/// it cannot be.
///
/// §7 of `Multi-Engine-Design.md` calls the preference migration the highest-risk
/// detail in the plan: the legacy `Model` key holds a bare `URL`, and Phase 2
/// replaces it with an engine-qualified `ModelID` while both local engines still
/// share one directory. The migration cannot be tested before it exists, so what
/// is pinned here is the contract it has to preserve — which model a user ends up
/// with, given what is on disk and what was persisted.
///
/// `loadModels()` is exercised directly rather than through `init`. The
/// initialiser only schedules it, and awaiting an unowned background task would
/// make these assertions racy for no added coverage.
@MainActor
struct ModelSelectionPersistenceTests {
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
        GenerationController(
            configStore: configStore,
            modelRepository: ModelRepository(),
            imageRepository: ImageRepository(),
            startsObserving: false
        )
    }

    /// Two Core ML models whose names sort `a-model` before `b-model`
    /// case-insensitively, so "the first model" is unambiguous.
    private func makeTwoModels() throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-model"))
        try makeSDModelFixture(at: modelDir.appending(path: "b-model"))
    }

    // MARK: - Restore

    @Test("With nothing persisted, the first model is selected and persisted")
    func firstModelIsSelectedAndPersisted() async throws {
        try makeTwoModels()
        let controller = makeController()

        await controller.loadModels()

        #expect(controller.currentModel?.name == "a-model")
        // Persisted as a side effect of currentModelId's didSet, so the next
        // launch restores rather than re-picks.
        #expect(configStore.modelId == controller.currentModelId)
    }

    @Test("A persisted selection is restored in preference to the first model")
    func persistedSelectionIsRestored() async throws {
        try makeTwoModels()
        // Persist an id the way the app does: one that discovery itself produced.
        // See `unresolvedPersistedPathIsNotMatched` for why a hand-built URL for
        // the same directory does not work.
        let discovery = makeController()
        await discovery.loadModels()
        configStore.modelId = try #require(discovery.models.first { $0.name == "b-model" }).id

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "b-model")
    }

    /// A model's identity is the exact `URL` that `contentsOfDirectory` handed
    /// back: symlinks already resolved (`/private/var/…`, not `/var/…`) and a
    /// trailing slash because it is a directory. Matching is plain `URL`
    /// equality, so a path naming the same directory in any other form misses,
    /// and the user silently gets the first model instead of theirs.
    ///
    /// Nothing in the app writes such a value today — `currentModelId.didSet` only
    /// ever persists a discovered id — so this is latent rather than live. It stops
    /// being latent as soon as anything else computes a model path: an importer, a
    /// URL scheme, a restored window state, or a moved models folder. §5.1 of
    /// `Multi-Engine-Design.md` calls for `ModelID.key` to be a relative path with
    /// pinned normalisation rules; when Phase 2 lands that, this known issue should
    /// start failing and be deleted.
    @Test("An unresolved persisted path does not match the discovered model")
    func unresolvedPersistedPathIsNotMatched() async throws {
        try makeTwoModels()
        configStore.modelId = modelDir.appending(path: "b-model")

        let controller = makeController()
        await controller.loadModels()

        withKnownIssue("Model identity is an exact URL match, so an equivalent path misses") {
            #expect(controller.currentModel?.name == "b-model")
        }
    }

    @Test("A selection that no longer exists falls back to the first model")
    func missingSelectionFallsBackToFirst() async throws {
        try makeTwoModels()
        configStore.modelId = modelDir.appending(path: "deleted-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "a-model")
        // The stale URL is replaced rather than left to fail again next launch.
        #expect(configStore.modelId == controller.currentModelId)
    }

    @Test("A selection survives a fresh controller over the same preferences")
    func selectionSurvivesRelaunch() async throws {
        try makeTwoModels()
        let first = makeController()
        await first.loadModels()
        let target = try #require(first.models.first { $0.name == "b-model" })
        first.currentModelId = target.id

        // A new controller reading the same store is what a relaunch looks like.
        let second = makeController()
        await second.loadModels()

        #expect(second.currentModel?.name == "b-model")
    }

    @Test("A Klein model is restored across a relaunch just like a Core ML model")
    func kleinSelectionSurvivesRelaunch() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        let first = makeController()
        await first.loadModels()
        first.currentModelId = try #require(first.models.first { $0.name == "b-klein" }).id

        let second = makeController()
        await second.loadModels()

        // Today both engines' models live in one directory and are told apart by
        // sniff order, so a restored URL is unqualified. Phase 2 makes the
        // persisted identity engine-qualified; this must keep working.
        #expect(second.currentModel?.name == "b-klein")
        #expect(second.currentModel is IrisFluxKleinModel)
    }

    // MARK: - Failure paths

    @Test("An empty model directory clears the persisted selection")
    func emptyDirectoryClearsSelection() async throws {
        configStore.modelId = modelDir.appending(path: "gone")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.isEmpty)
        #expect(controller.currentModel == nil)
        #expect(configStore.modelId == nil)
    }

    @Test("An unreadable model directory clears the persisted selection")
    func unreadableDirectoryClearsSelection() async throws {
        configStore.modelDir = temp.appending("does-not-exist").path(percentEncoded: false)
        configStore.modelId = modelDir.appending(path: "a-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.isEmpty)
        #expect(configStore.modelId == nil)
    }

    @Test("Losing the models directory clears a previously good selection")
    func selectionIsClearedWhenDirectoryDisappears() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()
        #expect(configStore.modelId != nil)

        try FileManager.default.removeItem(at: modelDir)
        await controller.loadModels()

        // The models list is deliberately left stale — only the persisted
        // selection is cleared — so the sidebar keeps showing what it had.
        #expect(configStore.modelId == nil)
    }

    // MARK: - Selection side effects

    @Test("Selecting a ControlNet-capable model offers its ControlNets")
    func selectingModelPopulatesControlNets() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "controlled"),
            inputSize: CGSize(width: 512, height: 512),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = makeController()

        await controller.loadModels()

        #expect(controller.controlNet == ["canny"])
    }

    @Test("Switching to a model without ControlNet clears the offered list")
    func switchingModelClearsControlNets() async throws {
        try makeSDModelFixture(
            at: modelDir.appending(path: "a-controlled"),
            inputSize: CGSize(width: 512, height: 512),
            unetName: "ControlledUnet.mlmodelc"
        )
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        try makeControlNetFixture(at: controlNetDir.appending(path: "canny.mlmodelc"))
        let controller = makeController()
        await controller.loadModels()
        #expect(controller.controlNet == ["canny"])

        controller.currentModelId = try #require(controller.models.first { $0.name == "b-klein" })
            .id

        #expect(controller.controlNet.isEmpty)
    }

    @Test("Selecting a model discards any configured ControlNet inputs")
    func selectingModelDiscardsControlNetInputs() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()
        await controller.setControlNet(name: "canny")
        #expect(!controller.currentControlNets.isEmpty)

        controller.currentModelId = try #require(controller.models.first { $0.name == "b-model" })
            .id

        #expect(controller.currentControlNets.isEmpty)
    }

    @Test("Selecting an unknown id leaves the persisted selection untouched")
    func unknownIdDoesNotPersist() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()
        let persisted = configStore.modelId

        controller.currentModelId = modelDir.appending(path: "not-a-model")

        // didSet only writes through when the id resolves to a known model, so
        // currentModelId and the persisted value disagree here.
        #expect(configStore.modelId == persisted)
        #expect(controller.currentModel == nil)
    }

    // MARK: - Selection by name

    /// `copyModelToPrompt` resolves a model by its display name, which §9.4 says
    /// has to grow engine awareness in Phase 2. Pinned as the baseline that change
    /// is measured against.
    ///
    /// `setSize(width:height:)` is deliberately not pinned: its model-name-prefix
    /// orientation matching is slated for deletion in Phase 4, and pinning
    /// behaviour we intend to remove is what made `kleinTakesPrecedenceOverCoreML`
    /// a liability.
    @Test("A model is selectable by display name")
    func setModelByName() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()

        controller.setModel("b-model")

        #expect(controller.currentModel?.name == "b-model")
    }

    @Test("An unmatched name leaves the current selection alone")
    func setModelIgnoresUnknownName() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()

        controller.setModel("some-other-users-model")

        #expect(controller.currentModel?.name == "a-model")
    }

    @Test("A name is matched across engines, since names carry no engine today")
    func setModelMatchesKleinByName() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        let controller = makeController()
        await controller.loadModels()

        controller.setModel("b-klein")

        // Today there is one flat list, so a name lookup crosses engines with no
        // ambiguity check. Phase 2 has to decide what happens when two engines
        // expose the same name.
        #expect(controller.currentModel is IrisFluxKleinModel)
    }
}
