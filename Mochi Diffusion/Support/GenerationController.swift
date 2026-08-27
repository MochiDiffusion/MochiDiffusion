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
                if let model = model as? SDModel {
                    controlNet = model.controlNet
                } else {
                    controlNet = []
                }
                currentControlNets = []

            }
        }
    }
    var currentModel: (any EngineModel)? {
        models.first(where: { $0.id == self.currentModelId })
    }

    private(set) var currentControlNets: [ControlNetInput] = []
    private var pendingSelectedImageFilename: String?

    private var modelFolderMonitorTask: Task<Void, Never>?
    private var controlNetFolderMonitorTask: Task<Void, Never>?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var controlNetDirDebounceTask: Task<Void, Never>?
    private var generationUpdatesTask: Task<Void, Never>?
    private var generationResultsTask: Task<Void, Never>?

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
        Task {
            await loadModels()
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
                // Every engine came back empty. Reported the way a single failed
                // load used to be, since from the user's side nothing is
                // selectable either way.
                throw SDImageGenerator.GeneratorError.noModelsFound
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
        } catch SDImageGenerator.GeneratorError.modelDirectoryNoAccess {
            logger.error("Couldn't access model directory.")
            configStore.selectedModel = nil
        } catch SDImageGenerator.GeneratorError.modelSubDirectoriesNoAccess {
            logger.error("Could not get model subdirectories.")
            await GenerationService.shared.updateStatus(
                .error("Could not get model subdirectories.")
            )
            configStore.selectedModel = nil
        } catch SDImageGenerator.GeneratorError.noModelsFound {
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
        setModel(sdi.model)
    }

    func setModel(_ modelName: String) {
        if let matchingModel = models.first(where: { $0.name == modelName }) {
            currentModelId = matchingModel.id
            return
        }
    }

    func copySizeToPrompt() {
        guard let sdi = ImageGallery.shared.selected() else { return }
        setSize(width: sdi.width, height: sdi.height)
    }

    func setSize(width: Int, height: Int) {
        func orientationCategory(width: Int, height: Int) -> Int {
            if width > height {
                return 1
            }
            if width < height {
                return -1
            }
            return 0
        }

        if let currentSDModel = currentModel as? SDModel {
            // Match model name prefix and orientation (portrait, landscape, square)
            // hacky special treatment for models with names like <model-name>_
            let currentOrientation = orientationCategory(width: width, height: height)
            let currentModelPrefix = currentSDModel.name.split(separator: "_").first
            if let matchingModel = models.first(where: {
                guard
                    let model = $0 as? SDModel,
                    model.name.split(separator: "_").first == currentModelPrefix,
                    let size = model.inputSize
                else { return false }

                let modelOrientation = orientationCategory(
                    width: Int(size.width),
                    height: Int(size.height)
                )
                return currentOrientation == modelOrientation
            }) {
                currentModelId = matchingModel.id
                return
            }
        } else {
            configStore.width = width
            configStore.height = height
        }
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
            imageType: configStore.imageType
        )

        let plan: GenerationPlan
        do {
            plan = try engine.plan(draft: draft, model: model)
        } catch {
            logger.error("\(engine.id.rawValue) could not plan a generation: \(error)")
            return nil
        }

        return GenerationRequest(
            modelID: model.id,
            displayName: model.name,
            capabilities: model.config.generationCapabilities,
            metadataFields: model.config.metadataFields,
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
            strength: draft.strength,
            stepCount: plan.stepCount,
            guidanceScale: draft.guidanceScale,
            scheduler: plan.scheduler,
            mlComputeUnit: plan.mlComputeUnit,
            useDenoisedIntermediates: draft.showGenerationPreview,
            seed: draft.seed,
            numberOfImages: draft.numberOfImages,
            imageDir: draft.imageDir,
            imageType: draft.imageType
        )
    }

    private func observeGenerationService() {
        generationUpdatesTask?.cancel()
        generationUpdatesTask = Task { [weak self] in
            let stream = await GenerationService.shared.updates()
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
    }

    private func observeGenerationResults() {
        generationResultsTask?.cancel()
        generationResultsTask = Task { [weak self] in
            let stream = await GenerationService.shared.results()
            for await result in stream {
                self?.apply(result)
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
        modelFolderMonitorTask?.cancel()
        let path = modelDirectoryPath()
        modelFolderMonitorTask = Task { [weak self] in
            guard let self else { return }
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                await self.loadModels()
            }
        }
    }

    private func startControlNetFolderMonitor() {
        controlNetFolderMonitorTask?.cancel()
        let path = controlNetDirectoryPath()
        controlNetFolderMonitorTask = Task { [weak self] in
            guard let self else { return }
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
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
