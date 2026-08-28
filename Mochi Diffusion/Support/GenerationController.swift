//
//  GenerationController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import SwiftUI
import os

@MainActor
@Observable
final class GenerationController {
    struct ControlNetInput {
        var name: String?
        var image: CGImage?
        var imageFilename: String?
    }

    private var logger = Logger()
    private(set) var configStore: ConfigStore
    private(set) var engineSettings: EngineSettingsStore
    private let modelRepository: ModelRepository
    private let engineRegistry: EngineRegistry
    private let imageRepository: ImageRepository
    private(set) var generationQueue = [GenerationRequest]()
    private(set) var currentGeneration: GenerationRequest?
    private(set) var models = [any EngineModel]()
    private(set) var controlNet: [String] = []
    var startingImage: CGImage?
    var startingImageFilename: String?
    var numberOfImages = 1.0
    var seed: UInt32 = 0

    var currentModelId: ModelID? {
        didSet {
            guard let model = models.first(where: { $0.id == self.currentModelId }) else {
                // Selecting nothing — an engine with no models — has to clear the
                // ControlNet state too. Leaving it would offer the previous
                // model's ControlNets for a model that is not selected.
                controlNet = []
                currentControlNets = []
                return
            }
            engineSettings.selectedEngine = model.id.engine
            engineSettings.setSelectedModel(model.id, for: model.id.engine)
            // From the constraint rather than a downcast: which ControlNets a
            // model can use is something it declares, not something the
            // controller reads off one engine's concrete type.
            controlNet = model.constraints.controlNet.names
            currentControlNets = []
        }
    }

    /// Every registered engine, for the picker. Unconfigured engines and engines
    /// with no models are included on purpose (§8).
    var engines: [AnyGenerationEngine] {
        engineRegistry.allEngines
    }

    /// Why each engine can or cannot be used, refreshed with every discovery pass.
    private(set) var engineAvailability: [EngineID: EngineAvailability] = [:]

    /// Increments per `loadModels()` call, so a pass that finishes after a newer one
    /// can tell and discard itself rather than overwriting it.
    private var loadGeneration = 0

    var selectedEngine: EngineID? {
        engineSettings.selectedEngine
    }

    /// The models the model picker shows: the selected engine's own.
    ///
    /// Falls back to every model when no engine is selected, which is the state
    /// before the first discovery pass finishes.
    var visibleModels: [any EngineModel] {
        guard let selectedEngine else { return models }
        return models.filter { $0.id.engine == selectedEngine }
    }

    /// Whether `engine` has anything to generate with right now.
    func hasModels(_ engine: EngineID) -> Bool {
        models.contains { $0.id.engine == engine }
    }

    /// Switches engine, restoring the model that engine was last using.
    ///
    /// An engine with no models leaves the selection empty rather than borrowing
    /// another engine's model: silently generating with a model from an engine the
    /// user did not pick is worse than an empty picker that says why (§8).
    func selectEngine(_ engine: EngineID) {
        guard engine != engineSettings.selectedEngine else { return }
        engineSettings.selectedEngine = engine
        currentModelId = rememberedOrFirstModel(for: engine)
    }

    private func rememberedOrFirstModel(for engine: EngineID) -> ModelID? {
        let candidates = models.filter { $0.id.engine == engine }
        if let remembered = engineSettings.selectedModel(for: engine),
            candidates.contains(where: { $0.id == remembered })
        {
            return remembered
        }
        return candidates.first?.id
    }
    var currentModel: (any EngineModel)? {
        models.first(where: { $0.id == self.currentModelId })
    }

    /// What the sidebar should offer. Falls back to
    /// `OptionConstraints.unconstrained` when no model is selected.
    var currentConstraints: OptionConstraints {
        currentModel?.constraints ?? .unconstrained
    }

    private(set) var currentControlNets: [ControlNetInput] = []
    private var pendingSelectedImageFilename: String?

    private var modelFolderMonitorTask: Task<Void, Never>?
    private var controlNetFolderMonitorTask: Task<Void, Never>?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var controlNetDirDebounceTask: Task<Void, Never>?
    private var generationUpdatesTask: Task<Void, Never>?
    private var generationResultsTask: Task<Void, Never>?
    /// Stored, and capturing weakly, so `shutdown()` can reach it. An
    /// unreferenced `Task` capturing `self` strongly would keep the controller
    /// alive until the load finished, with no handle to cancel.
    private var initialLoadTask: Task<Void, Never>?
    /// Checked before arming observation, scheduling a debounce or starting a
    /// monitor.
    ///
    /// A `withObservationTracking` callback stays armed until it fires, and firing
    /// is what re-registers it, so cancelling tasks alone does not stop a
    /// configuration change after `shutdown()` from scheduling fresh work.
    ///
    /// Also checked by `loadModels()` after its await. Cancellation is cooperative,
    /// so a refresh already past that point would otherwise mutate — and keep
    /// alive — a controller that has been shut down.
    private var isShutDown = false

    /// - Parameter startsObserving: whether to begin the eager work — the initial
    ///   model load, the folder monitors, and the generation-service observation.
    ///   The app always wants it. Tests opt out so the controller owns no
    ///   background task that can reload models, and therefore reassign
    ///   `currentModelId`, in the middle of their assertions: its `didSet` clears
    ///   `currentControlNets`, so a stray reload silently empties state a test
    ///   just set up.
    init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository(),
        engineRegistry: EngineRegistry = EngineRegistry(),
        engineSettings: EngineSettingsStore? = nil,
        startsObserving: Bool = true
    ) {
        self.configStore = configStore
        self.modelRepository = modelRepository
        self.engineRegistry = engineRegistry
        self.imageRepository = imageRepository
        // Defaulted from the registry rather than by the caller, so the store only
        // ever loads selections for engines that actually exist.
        self.engineSettings =
            engineSettings
            ?? EngineSettingsStore(
                store: configStore.defaults,
                engines: engineRegistry.engineIDs
            )
        guard startsObserving else { return }
        initialLoadTask = Task { [weak self] in
            await self?.loadModels()
        }
        startModelFolderMonitor()
        startControlNetFolderMonitor()
        observeModelDir()
        observeControlNetDir()
        observeGenerationService()
        observeGenerationResults()
    }

    func loadModels() async {
        loadGeneration += 1
        let generation = loadGeneration
        logger.info("Started loading model directory at: \"\(self.configStore.modelDir)\"")
        do {
            let modelDirectoryURL = ModelRepository.modelDirectoryURL(
                fromPath: configStore.modelDir
            )
            let controlNetDirectoryURL = ModelRepository.controlNetDirectoryURL(
                fromPath: configStore.controlNetDir)

            let settings = EngineSettings(
                modelDirectory: modelDirectoryURL,
                controlNetDirectory: controlNetDirectoryURL
            )
            // One aggregate pass: availability and discovery gathered together, so
            // this cannot pair one engine's availability with another pass's models.
            let refresh = await engineRegistry.refresh(settings: settings)

            // The two guards that make a refresh abandonable. `loadModels` is
            // started by the initial load, two folder monitors and two debounced
            // settings paths, and `@MainActor` serialises the *mutations* without
            // preventing reentrancy across the await above. Without the epoch, a
            // pass for the previous models folder could finish after a newer pass
            // and overwrite its models, availability and selection.
            guard generation == loadGeneration else {
                logger.info("Discarding a superseded model load")
                return
            }
            guard !isShutDown else { return }

            engineAvailability = refresh.availability
            let discoveries = refresh.discoveries
            let discoveredModels = refresh.models
            // Assigned before the check below, so a pass that finds nothing empties
            // the picker instead of leaving the previous pass's models on screen.
            self.models = discoveredModels
            guard !discoveredModels.isEmpty else {
                currentModelId = nil
                // "Nothing was found" and "nothing could be read" need different
                // messages: reporting an unreadable models folder as an empty one
                // sends the user looking for missing models when the problem is the
                // folder. Engines report their own reasons, which this single
                // message flattens.
                if discoveries.failures.isEmpty {
                    throw GenerationError.noModelsFound
                }
                throw GenerationError.modelSubDirectoriesNoAccess
            }

            // Two migrations, in order, both idempotent. The first recovers the
            // engine for a pre-engine `Model` URL by matching what discovery just
            // found; the second turns that single selection into an engine plus a
            // per-engine model. A user upgrading across both arrives with the model
            // they had selected still selected.
            configStore.migrateSelectedModelIfNeeded(discovered: self.models.map(\.id))
            engineSettings.migrateSelectedEngineIfNeeded(
                from: configStore.selectedModel,
                discovered: self.models.map(\.id)
            )

            logger.info("Found \(self.models.count) model(s)")
            restoreSelection()
        } catch GenerationError.modelDirectoryNoAccess {
            logger.error("Couldn't access model directory.")
            currentModelId = nil
        } catch GenerationError.modelSubDirectoriesNoAccess {
            logger.error("Could not get model subdirectories.")
            await GenerationService.shared.updateStatus(
                .error("Could not get model subdirectories.")
            )
            currentModelId = nil
        } catch GenerationError.noModelsFound {
            logger.error("No models found.")
            await GenerationService.shared.updateStatus(
                .error("No models found under: \(configStore.modelDir)")
            )
            currentModelId = nil
        } catch {
            currentModelId = nil
        }
    }

    /// Picks the engine and model to show after a discovery pass.
    ///
    /// A persisted engine is kept even when it has no models, so the picker can
    /// say why rather than moving the user to an engine they did not choose. With
    /// no engine persisted — a first launch, or a selection whose engine is no
    /// longer registered — the first engine that actually has a model is chosen,
    /// in registration order, so the sidebar is never pointlessly empty.
    private func restoreSelection() {
        if let engine = engineSettings.selectedEngine, engines.contains(where: { $0.id == engine })
        {
            currentModelId = rememberedOrFirstModel(for: engine)
            return
        }
        // The engine of the first model in the combined list, not the first engine
        // in registration order. `models` is sorted by name, so this lands on the
        // same model the app picked before engines were selectable; going by
        // registration order would instead make Iris the default for any mixed
        // folder, which is arbitrary and would change what a fresh install opens
        // with.
        guard let firstModel = models.first else {
            currentModelId = nil
            return
        }
        engineSettings.selectedEngine = firstModel.id.engine
        currentModelId = rememberedOrFirstModel(for: firstModel.id.engine)
    }

    func generate() async {
        guard let request = buildGenerationRequest() else { return }
        // Both engines write through ImageRepository, so an unwritable images
        // folder should surface before the job is queued rather than after it runs.
        do {
            _ = try await imageRepository.ensureOutputDirectory(
                imageDir: request.imageDir
            )
        } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
            await GenerationService.shared.updateStatus(
                .error("Couldn't access images folder at: \(path)")
            )
            return
        } catch {
            await GenerationService.shared.updateStatus(
                .error("Couldn't access images folder.")
            )
            return
        }

        await GenerationService.shared.enqueue(request)
    }

    func setStartingImage(image: CGImage, filename: String? = nil) {
        startingImage = image
        startingImageFilename =
            filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
    }

    func selectStartingImage() async {
        guard let image = await selectImage() else { return }
        setStartingImage(image: image)
    }

    func selectStartingImage(sdi: SDImage) async {
        guard let image = sdi.image else { return }
        let filename = URL(fileURLWithPath: sdi.path).lastPathComponent
        setStartingImage(image: image, filename: filename)
    }

    func unsetStartingImage() async {
        startingImage = nil
        startingImageFilename = nil
    }

    func setControlNet(name: String) async {
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [ControlNetInput(name: name, image: nil, imageFilename: nil)]
        } else {
            self.currentControlNets[0].name = name
        }
    }

    func setControlNet(image: CGImage, filename: String? = nil) async {
        let imageFilename = filename?.normalizedFilename ?? consumePendingSelectedImageFilename()
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            ]
        } else {
            self.currentControlNets[0].image = image
            self.currentControlNets[0].imageFilename = imageFilename
        }
    }

    func unsetControlNet() async {
        self.currentControlNets = []
    }

    func selectControlNetImage(at index: Int) async {
        guard let image = await selectImage() else { return }
        let imageFilename = consumePendingSelectedImageFilename()

        if currentControlNets.isEmpty {
            currentControlNets = [
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            ]
        } else if index >= currentControlNets.count {
            currentControlNets.append(
                ControlNetInput(name: nil, image: image, imageFilename: imageFilename)
            )
        } else {
            currentControlNets[index].image = image
            currentControlNets[index].imageFilename = imageFilename
        }
    }

    func unsetControlNetImage(at index: Int) async {
        guard index < currentControlNets.count else { return }
        currentControlNets[index].image = nil
        currentControlNets[index].imageFilename = nil
    }

    func selectImage() async -> CGImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(
            localized: "Choose image",
            comment: "Message text for choosing starting image or ControlNet image")
        panel.prompt = String(localized: "Select", comment: "OK button text for choose image panel")
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return nil
        }

        guard let url = panel.url else { return nil }
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
        pendingSelectedImageFilename = url.lastPathComponent

        return CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil)
    }

    private func consumePendingSelectedImageFilename() -> String? {
        defer { pendingSelectedImageFilename = nil }
        return pendingSelectedImageFilename?.normalizedFilename
    }

    func copyToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        copyToPrompt(sdi)
    }

    func copyToPrompt(_ sdi: SDImage) {
        let metadataFields = ImageGallery.shared.metadataFields(for: sdi.id)

        if metadataFields.contains(.prompt) {
            configStore.prompt = sdi.prompt
        }
        if metadataFields.contains(.negativePrompt) {
            configStore.negativePrompt = sdi.negativePrompt
        }
        if metadataFields.contains(.steps) {
            configStore.steps = Double(sdi.steps)
        }
        if metadataFields.contains(.guidanceScale) {
            configStore.guidanceScale = sdi.guidanceScale
        }
        if metadataFields.contains(.size) {
            configStore.width = sdi.width
            configStore.height = sdi.height
        }
        if metadataFields.contains(.seed) {
            seed = sdi.seed
        }
        if metadataFields.contains(.scheduler) {
            configStore.scheduler = sdi.scheduler
        }
    }

    func copyPromptToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        configStore.prompt = sdi.prompt
    }

    func copyModelToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        selectModel(named: sdi.model, engine: sdi.engine, key: sdi.modelKey)
    }

    /// Selects the model a gallery image was generated with.
    ///
    /// An image whose metadata records an engine and key resolves exactly. Older
    /// images carry only a display name, which two engines may both offer — see
    /// `setModel(_:)` for how that ambiguity is settled.
    func selectModel(named name: String, engine: String, key: String) {
        if !engine.isEmpty, !key.isEmpty {
            let id = ModelID(engine: EngineID(rawValue: engine), key: key)
            if models.contains(where: { $0.id == id }) {
                currentModelId = id
                return
            }
        }
        setModel(name)
    }

    /// Selects a model by display name, which is all a pre-engine image recorded.
    ///
    /// Prefers the engine already selected, so a name two engines both offer does
    /// not move the user off the engine they are working in. Failing that, a
    /// single unambiguous match elsewhere is taken — refusing would leave the
    /// menu command appearing to do nothing, which is worse than switching. If
    /// several engines offer the name, the selection is left alone rather than
    /// guessed at.
    func setModel(_ modelName: String) {
        let matches = models.filter { $0.name == modelName }
        guard !matches.isEmpty else { return }

        if let currentEngine = currentModelId?.engine,
            let sameEngine = matches.first(where: { $0.id.engine == currentEngine })
        {
            currentModelId = sameEngine.id
            return
        }
        if matches.count == 1 {
            currentModelId = matches[0].id
        }
    }

    func copySizeToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        setSize(width: sdi.width, height: sdi.height)
    }

    /// Applies a size, which for some engines means selecting a different model.
    ///
    /// Core ML models are converted at a fixed resolution and usually ship as a
    /// per-orientation set, so a size the current model cannot produce may be
    /// another model's. The engine answers whether such a model exists, so this
    /// does not have to know how any engine names its files.
    func setSize(width: Int, height: Int) {
        guard let model = currentModel else { return }
        let size = CGSize(width: width, height: height)

        if model.constraints.size.isEditable {
            configStore.width = width
            configStore.height = height
            return
        }

        guard
            let engine = engineRegistry.engine(model.id.engine),
            let variant = engine.model(
                forSize: size,
                among: models.filter { $0.id.engine == model.id.engine },
                current: model
            )
        else { return }
        currentModelId = variant.id
    }

    /// Whether `setSize(width:height:)` would change anything, so the sidebar
    /// can hide a swap control that would silently do nothing.
    func canSetSize(width: Int, height: Int) -> Bool {
        guard let model = currentModel else { return false }
        if model.constraints.size.isEditable { return true }
        guard let engine = engineRegistry.engine(model.id.engine) else { return false }
        let variant = engine.model(
            forSize: CGSize(width: width, height: height),
            among: models.filter { $0.id.engine == model.id.engine },
            current: model
        )
        return variant != nil && variant?.id != model.id
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        configStore.negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        configStore.scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        configStore.steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        configStore.guidanceScale = sdi.guidanceScale
    }

    /// Gathers the sidebar into a `GenerationDraft`, hands it to the selected
    /// model's engine to resolve, and copies the resulting plan into a request.
    /// Every per-engine decision belongs to that engine's `plan`.
    ///
    /// Internal rather than private so tests can assert the exact request the app
    /// builds.
    func buildGenerationRequest() -> GenerationRequest? {
        guard let model = currentModel else { return nil }
        guard let engine = engineRegistry.engine(model.id.engine) else {
            logger.error("no engine registered for \(model.id.description)")
            return nil
        }

        let draft = GenerationDraft(
            prompt: configStore.prompt,
            negativePrompt: configStore.negativePrompt,
            configuredSize: CGSize(width: configStore.width, height: configStore.height),
            startingImage: startingImage,
            startingImageName: startingImageFilename,
            controlNets: currentControlNets.map {
                ControlNetDraft(name: $0.name, image: $0.image, imageName: $0.imageFilename)
            },
            strength: Float(configStore.strength),
            stepCount: Int(configStore.steps),
            guidanceScale: Float(configStore.guidanceScale),
            scheduler: configStore.scheduler,
            quality: configStore.quality,
            seed: seed == 0 ? UInt32.random(in: 0..<UInt32.max) : seed,
            numberOfImages: Int(numberOfImages),
            computeUnitPreference: configStore.mlComputeUnitPreference,
            reduceMemory: configStore.reduceMemory,
            safetyChecker: configStore.safetyChecker,
            showGenerationPreview: configStore.showGenerationPreview,
            imageDir: configStore.imageDir,
            imageType: configStore.imageType,
            controlNetDirectory: ModelRepository.controlNetDirectoryURL(
                fromPath: configStore.controlNetDir
            )
        )

        let plan: GenerationPlan<any Sendable>
        do {
            plan = try engine.plan(draft: draft, model: model)
        } catch {
            logger.error("\(engine.id.rawValue) could not plan a generation: \(error)")
            return nil
        }

        return GenerationRequest(
            modelID: model.id,
            displayName: model.name,
            metadataFields: model.metadataFields,
            payload: plan.payload,
            prompt: draft.prompt,
            negativePrompt: draft.negativePrompt,
            size: plan.size,
            startingImageData: plan.startingImageData,
            startingImageName: plan.startingImageName,
            controlNetImageData: plan.controlNetImageData,
            controlNetNames: plan.controlNetNames,
            controlNetImageNames: plan.controlNetImageNames,
            inputImageNames: plan.inputImageNames,
            strength: plan.strength,
            stepCount: plan.stepCount,
            guidanceScale: plan.guidanceScale,
            scheduler: plan.scheduler,
            quality: plan.quality,
            mlComputeUnit: plan.mlComputeUnit,
            useDenoisedIntermediates: draft.showGenerationPreview,
            seed: draft.seed,
            numberOfImages: plan.numberOfImages,
            imageDir: draft.imageDir,
            imageType: draft.imageType
        )
    }

    /// Cancels every task this controller owns and stops it starting new ones.
    ///
    /// The observation loops iterate streams that never end by themselves, so
    /// without this they keep consuming after the controller is finished with.
    /// Call before releasing a controller that was constructed with
    /// `startsObserving: true`.
    func shutdown() {
        isShutDown = true
        initialLoadTask?.cancel()
        generationUpdatesTask?.cancel()
        generationResultsTask?.cancel()
        modelFolderMonitorTask?.cancel()
        controlNetFolderMonitorTask?.cancel()
        modelDirDebounceTask?.cancel()
        controlNetDirDebounceTask?.cancel()
        initialLoadTask = nil
        generationUpdatesTask = nil
        generationResultsTask = nil
        modelFolderMonitorTask = nil
        controlNetFolderMonitorTask = nil
        modelDirDebounceTask = nil
        controlNetDirDebounceTask = nil
    }

    private func observeGenerationService() {
        generationUpdatesTask?.cancel()
        generationUpdatesTask = Task { [weak self] in
            let stream = await GenerationService.shared.updates()
            for await snapshot in stream {
                guard let self else { return }
                self.apply(snapshot)
            }
        }
    }

    private func observeGenerationResults() {
        generationResultsTask?.cancel()
        generationResultsTask = Task { [weak self] in
            let stream = await GenerationService.shared.results()
            for await result in stream {
                guard let self else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ snapshot: GenerationService.Snapshot) {
        generationQueue = snapshot.queue
        currentGeneration = snapshot.current
    }

    private func apply(_ result: GenerationResult) {
        let shouldAnimateInsert = ImageGallery.shared.currentGeneratingImage == nil
        defer {
            // Scoped to the request that produced this result. Results arrive on
            // their own channel and can be applied after the next request has put
            // its first preview up; clearing unconditionally erased it.
            if let requestID = result.requestID {
                ImageGallery.shared.clearCurrentGenerating(owner: requestID)
            } else {
                ImageGallery.shared.clearCurrentGenerating()
            }
        }
        guard let url = result.imageURL else { return }
        let metadata = result.metadata
        let width = metadata.width
        let height = metadata.height
        let aspectRatio = height > 0 ? Double(width) / Double(height) : 0
        let record = ImageRecord(
            id: result.id,
            prompt: metadata.prompt,
            negativePrompt: metadata.negativePrompt,
            width: width,
            height: height,
            aspectRatio: aspectRatio,
            model: metadata.model,
            engine: metadata.engine,
            modelKey: metadata.modelKey,
            quality: metadata.quality,
            startingImage: metadata.startingImage,
            controlNetImage: metadata.controlNetImage,
            inputImages: metadata.inputImages,
            scheduler: metadata.scheduler,
            mlComputeUnit: metadata.mlComputeUnit,
            seed: metadata.seed,
            steps: metadata.steps,
            guidanceScale: metadata.guidanceScale,
            metadataFields: metadata.metadataFields,
            generatedDate: metadata.generatedDate,
            path: url.path(percentEncoded: false),
            finderTagColorNumber: 0,
            imageData: result.imageData
        )
        guard let sdi = createSDImage(from: record) else { return }
        ImageGallery.shared.add(
            sdi,
            metadataFields: metadata.metadataFields,
            animate: shouldAnimateInsert
        )
    }

    func removeQueued(_ id: GenerationRequest.ID) async {
        await GenerationService.shared.removeQueued(id: id)
    }

    private func observeModelDir() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = configStore.modelDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleModelDirUpdate()
                self?.observeModelDir()
            }
        }
    }

    private func observeControlNetDir() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = configStore.controlNetDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleControlNetDirUpdate()
                self?.observeControlNetDir()
            }
        }
    }

    private func scheduleModelDirUpdate() {
        guard !isShutDown else { return }
        modelDirDebounceTask?.cancel()
        modelDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateModelFolderMonitor()
        }
    }

    private func scheduleControlNetDirUpdate() {
        guard !isShutDown else { return }
        controlNetDirDebounceTask?.cancel()
        controlNetDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateControlNetFolderMonitor()
        }
    }

    private func updateModelFolderMonitor() async {
        startModelFolderMonitor()
        await loadModels()
    }

    private func updateControlNetFolderMonitor() async {
        startControlNetFolderMonitor()
        await loadModels()
    }

    private func startModelFolderMonitor() {
        guard !isShutDown else { return }
        modelFolderMonitorTask?.cancel()
        let path = modelDirectoryPath()
        modelFolderMonitorTask = Task { [weak self] in
            // Weak *inside* the loop, not before it. Hoisting `self` out kept the
            // controller alive for as long as the task ran, and the task ran
            // forever, so neither could be released.
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                guard let self else { return }
                await self.loadModels()
            }
        }
    }

    private func startControlNetFolderMonitor() {
        guard !isShutDown else { return }
        controlNetFolderMonitorTask?.cancel()
        let path = controlNetDirectoryPath()
        controlNetFolderMonitorTask = Task { [weak self] in
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                guard let self else { return }
                await self.loadModels()
            }
        }
    }

    private func modelDirectoryPath() -> String {
        ModelRepository.modelDirectoryURL(fromPath: configStore.modelDir)
            .path(percentEncoded: false)
    }

    private func controlNetDirectoryPath() -> String {
        ModelRepository.controlNetDirectoryURL(fromPath: configStore.controlNetDir)
            .path(percentEncoded: false)
    }
}
