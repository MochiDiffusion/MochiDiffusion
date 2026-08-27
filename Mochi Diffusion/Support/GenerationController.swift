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
            if let model = models.first(where: { $0.id == self.currentModelId }) {
                configStore.selectedModel = currentModelId
                // From the constraint rather than a downcast: which ControlNets a
                // model can use is something it declares, not something the
                // controller reads off one engine's concrete type.
                controlNet = model.constraints.controlNet.names
                currentControlNets = []
            }
        }
    }
    var currentModel: (any EngineModel)? {
        models.first(where: { $0.id == self.currentModelId })
    }

    /// What the sidebar should offer. Falls back to
    /// ``OptionConstraints/unconstrained`` when no model is selected.
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
    /// Stored, and weak inside, so `shutdown()` can reach it. It used to be a
    /// bare `Task { await loadModels() }`, which captured `self` strongly and was
    /// held by nothing — so it kept the controller alive until the load finished
    /// and `shutdown()` had no handle to cancel.
    private var initialLoadTask: Task<Void, Never>?
    /// `withObservationTracking` callbacks stay armed until they fire, and firing
    /// is what re-registers them. Cancelling tasks therefore does not stop a
    /// configuration change after `shutdown()` from scheduling fresh debounce work
    /// and arming observation all over again, so shutdown was not terminal.
    private var isShutDown = false

    /// - Parameter startsObserving: whether to begin the eager work — the initial
    ///   model load, the folder monitors, and the generation-service observation.
    ///   The app always wants it. Tests opt out so the controller owns no
    ///   background task that can reload models, and therefore reassign
    ///   `currentModelId`, in the middle of their assertions; `currentModelId`'s
    ///   `didSet` clears `currentControlNets`, so a stray reload silently empties
    ///   state a test just set up. §11.5 of `Multi-Engine-Design.md` wants this
    ///   seam to grow into an explicit lifecycle with a matching shutdown path.
    init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository(),
        engineRegistry: EngineRegistry = EngineRegistry(),
        startsObserving: Bool = true
    ) {
        self.configStore = configStore
        self.modelRepository = modelRepository
        self.engineRegistry = engineRegistry
        self.imageRepository = imageRepository
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
        logger.info("Started loading model directory at: \"\(self.configStore.modelDir)\"")
        do {
            let modelDirectoryURL = ModelRepository.modelDirectoryURL(
                fromPath: configStore.modelDir
            )
            let controlNetDirectoryURL = ModelRepository.controlNetDirectoryURL(
                fromPath: configStore.controlNetDir)

            let discoveries = await engineRegistry.discoverAll(
                settings: EngineSettings(
                    modelDirectory: modelDirectoryURL,
                    controlNetDirectory: controlNetDirectoryURL
                )
            )
            for (engine, error) in discoveries.failures {
                logger.error("\(engine.rawValue) found no models: \(error)")
            }

            let discoveredModels = discoveries.allModels
            guard !discoveredModels.isEmpty else {
                // "Nothing was found" and "nothing could be read" need different
                // messages. Reporting an unreadable models folder as an empty one
                // sends the user looking for missing models when the problem is
                // the folder, and it made the access-error branch below
                // unreachable. Phase 5's picker replaces this single global
                // message with per-engine availability reasons.
                if discoveries.failures.isEmpty {
                    throw GenerationError.noModelsFound
                }
                throw GenerationError.modelSubDirectoriesNoAccess
            }
            self.models = discoveredModels

            // After discovery and before the selection is read: recovering the
            // engine for a legacy URL means matching what discovery found, so a
            // user upgrading keeps the model they had selected.
            configStore.migrateSelectedModelIfNeeded(discovered: self.models.map(\.id))

            logger.info("Found \(self.models.count) model(s)")

            /// Try restoring last user selected model
            /// If not found, use first model from list
            if self.models.first(where: { $0.id == configStore.selectedModel }) != nil {
                self.currentModelId = configStore.selectedModel
                return
            }
            self.currentModelId = self.models.first?.id
        } catch GenerationError.modelDirectoryNoAccess {
            logger.error("Couldn't access model directory.")
            configStore.selectedModel = nil
        } catch GenerationError.modelSubDirectoriesNoAccess {
            logger.error("Could not get model subdirectories.")
            await GenerationService.shared.updateStatus(
                .error("Could not get model subdirectories.")
            )
            configStore.selectedModel = nil
        } catch GenerationError.noModelsFound {
            logger.error("No models found.")
            await GenerationService.shared.updateStatus(
                .error("No models found under: \(configStore.modelDir)")
            )
            configStore.selectedModel = nil
        } catch {
            configStore.selectedModel = nil
        }
    }

    func generate() async {
        guard let request = buildGenerationRequest() else { return }
        // Core ML writes through ImageRepository, so a bad images folder should
        // surface before the job is queued rather than after it runs. Iris takes
        // the same path, so the check is no longer conditional.
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
    /// An image written since engines exist records its engine and key, so it can
    /// be resolved exactly. Older images carry only a display name, which is the
    /// ambiguity §9.4 of `Multi-Engine-Design.md` is about.
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
    /// another model's. The engine answers whether such a model exists — the
    /// name-prefix search used to live here, which meant the controller knew how
    /// one engine names its files.
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

    /// Whether ``setSize(width:height:)`` would change anything, so the sidebar
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

    /// Internal rather than private so the regression suite can assert the exact
    /// request the app builds. The per-engine branches this used to hold now live
    /// in each engine's `plan`; what is left is gathering the sidebar into a draft
    /// and copying the resolved plan into the request.
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
            mlComputeUnit: plan.mlComputeUnit,
            useDenoisedIntermediates: draft.showGenerationPreview,
            seed: draft.seed,
            numberOfImages: plan.numberOfImages,
            imageDir: draft.imageDir,
            imageType: draft.imageType
        )
    }

    /// Cancels every task this controller owns.
    ///
    /// The observation loops iterate streams that never end on their own, so
    /// without this they keep consuming after the controller is finished with.
    /// The folder monitors were worse: they promoted `self` to a strong reference
    /// before entering the loop, so task and controller kept each other alive
    /// until something cancelled — which nothing did. See §11.6.
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
            ImageGallery.shared.setCurrentGenerating(image: nil)
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
