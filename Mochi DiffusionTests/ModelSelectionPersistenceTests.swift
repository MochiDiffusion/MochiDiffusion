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
@Suite(.serialized)
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

    /// The message the app is showing, or `nil` if it is not in an error state.
    /// `GenerationState` is a singleton, hence `.serialized` on this suite.
    private func statusMessage() -> String? {
        if case .error(let message) = GenerationState.shared.state { return message }
        return nil
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
        #expect(configStore.selectedModel == controller.currentModelId)
    }

    @Test("A persisted selection is restored in preference to the first model")
    func persistedSelectionIsRestored() async throws {
        try makeTwoModels()
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "b-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "b-model")
    }

    /// Identity used to be the exact `URL` `contentsOfDirectory` returned —
    /// symlinks resolved, trailing slash — matched by plain equality, so a path
    /// naming the same directory in any other spelling missed and the user
    /// silently got the first model instead of theirs. This was a `withKnownIssue`
    /// until `ModelID` replaced URL identity: a key is the directory's own name,
    /// so there is only one spelling left to get wrong.
    @Test("A selection is restored however the models directory is spelled")
    func selectionIsIndependentOfPathSpelling() async throws {
        try makeTwoModels()
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "b-model")
        // /private/var and /var name the same directory: enumeration returns the
        // first, settings hold the second.
        configStore.modelDir = "/private" + modelDir.path(percentEncoded: false)

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "b-model")
    }

    @Test("A selection naming another engine's model is not restored")
    func selectionIsEngineQualified() async throws {
        try makeTwoModels()
        // Same key, wrong engine: these are Core ML directories, not Iris ones.
        configStore.selectedModel = ModelID(engine: .iris, key: "b-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "a-model")
    }

    @Test("A selection that no longer exists falls back to the first model")
    func missingSelectionFallsBackToFirst() async throws {
        try makeTwoModels()
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "deleted-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.currentModel?.name == "a-model")
        // The stale key is replaced rather than left to fail again next launch.
        #expect(configStore.selectedModel == controller.currentModelId)
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
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "gone")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.isEmpty)
        #expect(controller.currentModel == nil)
        #expect(configStore.selectedModel == nil)
        #expect(statusMessage()?.contains("No models found") == true)
    }

    /// A readable-but-empty folder and an unreadable one need different messages.
    /// Reporting the second as the first sends the user looking for missing models
    /// when the problem is the folder itself.
    @Test("An unreadable models directory reports an access error, not an empty folder")
    func unreadableDirectoryReportsAccessError() async throws {
        configStore.modelDir = temp.appending("does-not-exist").path(percentEncoded: false)

        let controller = makeController()
        await controller.loadModels()

        let message = try #require(statusMessage())
        #expect(message.contains("subdirectories"))
        #expect(!message.contains("No models found"))
    }

    @Test("An unreadable model directory clears the persisted selection")
    func unreadableDirectoryClearsSelection() async throws {
        configStore.modelDir = temp.appending("does-not-exist").path(percentEncoded: false)
        configStore.selectedModel = ModelID(engine: .coreMLStableDiffusion, key: "a-model")

        let controller = makeController()
        await controller.loadModels()

        #expect(controller.models.isEmpty)
        #expect(configStore.selectedModel == nil)
    }

    @Test("Losing the models directory clears a previously good selection")
    func selectionIsClearedWhenDirectoryDisappears() async throws {
        try makeTwoModels()
        let controller = makeController()
        await controller.loadModels()
        #expect(configStore.selectedModel != nil)

        try FileManager.default.removeItem(at: modelDir)
        await controller.loadModels()

        // The models list is deliberately left stale — only the persisted
        // selection is cleared — so the sidebar keeps showing what it had.
        #expect(configStore.selectedModel == nil)
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
        let persisted = configStore.selectedModel

        controller.currentModelId = ModelID(engine: .coreMLStableDiffusion, key: "not-a-model")

        // didSet only writes through when the id resolves to a known model, so
        // currentModelId and the persisted value disagree here.
        #expect(configStore.selectedModel == persisted)
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

    @Test("A single unambiguous name match is taken even across engines")
    func setModelMatchesKleinByName() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        let controller = makeController()
        await controller.loadModels()

        controller.setModel("b-klein")

        // Only one model has this name, so switching engines is unambiguous.
        // Refusing would leave "copy model to prompt" appearing to do nothing.
        #expect(controller.currentModel is IrisFluxKleinModel)
    }

    /// §9.4: independent discovery means one directory can be offered by two
    /// engines under the same display name, so a name alone stopped being enough.
    @Test("A name both engines offer keeps the engine already selected")
    func setModelPrefersTheCurrentEngine() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)
        let controller = makeController()
        await controller.loadModels()
        controller.currentModelId = ModelID(engine: .coreMLStableDiffusion, key: "ambiguous")

        controller.setModel("ambiguous")

        // Staying put beats guessing: the user is working in one engine and a
        // name collision should not move them out of it.
        #expect(controller.currentModelId?.engine == .coreMLStableDiffusion)
    }

    @Test("An image that recorded its engine resolves to exactly that model")
    func selectModelUsesRecordedEngineIdentity() async throws {
        let ambiguous = modelDir.appending(path: "ambiguous")
        try makeKleinModelFixture(at: ambiguous)
        try makeSDModelFixture(at: ambiguous)
        let controller = makeController()
        await controller.loadModels()
        controller.currentModelId = ModelID(engine: .coreMLStableDiffusion, key: "ambiguous")

        controller.selectModel(named: "ambiguous", engine: "iris", key: "ambiguous")

        // Written since engines exist, so there is nothing to infer.
        #expect(controller.currentModelId == ModelID(engine: .iris, key: "ambiguous"))
    }

    @Test("A pre-engine image falls back to matching by name")
    func selectModelFallsBackToNameForLegacyImages() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        try makeKleinModelFixture(at: modelDir.appending(path: "b-klein"))
        let controller = makeController()
        await controller.loadModels()

        controller.selectModel(named: "b-klein", engine: "", key: "")

        #expect(controller.currentModel?.name == "b-klein")
    }

    @Test("A recorded engine that no longer resolves falls back to the name")
    func selectModelFallsBackWhenRecordedIdIsGone() async throws {
        try makeSDModelFixture(at: modelDir.appending(path: "a-coreml"))
        let controller = makeController()
        await controller.loadModels()

        controller.selectModel(named: "a-coreml", engine: "openai", key: "gpt-image-1")

        // An image generated by an engine this install does not have, or a model
        // since deleted, still resolves as far as the name allows.
        #expect(controller.currentModel?.name == "a-coreml")
    }
}
