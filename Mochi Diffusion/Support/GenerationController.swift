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
    private enum PipelineModelAdapter {
        case sd(SDModel)
        case irisFluxKlein(IrisFluxKleinModel)

        static func from(_ model: any MochiModel) -> PipelineModelAdapter? {
            switch model {
            case let model as SDModel:
                return .sd(model)
            case let model as IrisFluxKleinModel:
                return .irisFluxKlein(model)
            default:
                return nil
            }
        }

        var inputSize: CGSize? {
            switch self {
            case .sd(let model):
                return model.inputSize
            case .irisFluxKlein:
                return nil
            }
        }

        func makePipeline(configStore: ConfigStore, controlNets: [String]) -> GenerationPipeline {
            switch self {
            case .sd(let model):
                return .sd(
                    model: model,
                    computeUnit: configStore.mlComputeUnitPreference.computeUnits(forModel: model),
                    controlNets: controlNets,
                    reduceMemory: configStore.reduceMemory
                )
            case .irisFluxKlein(let model):
                return .iris(
                    modelDir: model.url.path(percentEncoded: false),
                    family: .fluxKlein
                )
            }
        }
    }

    struct ControlNetInput {
        var name: String?
        var image: CGImage?
        var imageFilename: String?
    }

    private var logger = Logger()
    private(set) var configStore: ConfigStore
    private let modelRepository: ModelRepository
    private let imageRepository: ImageRepository
    private let generationService: GenerationService
    private let generationState: GenerationState
    private let imageGallery: ImageGallery
    private(set) var generationQueue = [GenerationRequest]()
    private(set) var currentGeneration: GenerationRequest?
    private(set) var models = [any MochiModel]()
    private(set) var controlNet: [String] = []
    var startingImage: CGImage?
    var startingImageFilename: String?
    var numberOfImages = 1.0
    var seed: UInt32 = 0

    var currentModelId: URL? {
        didSet {
            if let model = models.first(where: { $0.id == self.currentModelId }) {
                configStore.modelId = currentModelId
                if let model = model as? SDModel {
                    controlNet = model.controlNet
                } else {
                    controlNet = []
                }
                currentControlNets = []

            }
        }
    }
    var currentModel: (any MochiModel)? {
        models.first(where: { $0.id == self.currentModelId })
    }

    private(set) var currentControlNets: [ControlNetInput] = []
    private var pendingSelectedImageFilename: String?

    private var modelFolderMonitor: FolderMonitor?
    private var controlNetFolderMonitor: FolderMonitor?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var controlNetDirDebounceTask: Task<Void, Never>?
    private var generationUpdatesTask: Task<Void, Never>?
    private var generationResultsTask: Task<Void, Never>?
    private var generationStatusTask: Task<Void, Never>?
    private var generationPreviewTask: Task<Void, Never>?

    init(
        configStore: ConfigStore,
        generationService: GenerationService,
        generationState: GenerationState,
        imageGallery: ImageGallery,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository()
    ) {
        self.configStore = configStore
        self.generationService = generationService
        self.generationState = generationState
        self.imageGallery = imageGallery
        self.modelRepository = modelRepository
        self.imageRepository = imageRepository
        Task {
            await loadModels()
        }
        startModelFolderMonitor()
        startControlNetFolderMonitor()
        observeModelDir()
        observeControlNetDir()
        observeGenerationService()
        observeGenerationResults()
        observeGenerationStatus()
        observeGenerationPreview()
    }

    convenience init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository()
    ) {
        let generationState = GenerationState()
        let imageGallery = ImageGallery()
        let generationService = GenerationService()
        self.init(
            configStore: configStore,
            generationService: generationService,
            generationState: generationState,
            imageGallery: imageGallery,
            modelRepository: modelRepository,
            imageRepository: imageRepository
        )
    }

    func loadModels() async {
        logger.info("Started loading model directory at: \"\(self.configStore.modelDir)\"")
        do {
            let modelDirectoryURL = ModelRepository.modelDirectoryURL(
                fromPath: configStore.modelDir
            )
            let controlNetDirectoryURL = ModelRepository.controlNetDirectoryURL(
                fromPath: configStore.controlNetDir)

            self.models = try await modelRepository.load(
                modelDir: modelDirectoryURL,
                controlNetDir: controlNetDirectoryURL
            )

            logger.info("Found \(self.models.count) model(s)")

            /// Try restoring last user selected model
            /// If not found, use first model from list
            if self.models.first(where: { $0.id == configStore.modelId }) != nil {
                self.currentModelId = configStore.modelId
                return
            }
            self.currentModelId = self.models.first?.id
        } catch SDImageGenerator.GeneratorError.modelDirectoryNoAccess {
            logger.error("Couldn't access model directory.")
            configStore.modelId = nil
        } catch SDImageGenerator.GeneratorError.modelSubDirectoriesNoAccess {
            logger.error("Could not get model subdirectories.")
            await generationService.updateStatus(
                .error("Could not get model subdirectories.")
            )
            configStore.modelId = nil
        } catch SDImageGenerator.GeneratorError.noModelsFound {
            logger.error("No models found.")
            await generationService.updateStatus(
                .error("No models found under: \(configStore.modelDir)")
            )
            configStore.modelId = nil
        } catch {
            configStore.modelId = nil
        }
    }

    func generate() async {
        guard let request = buildGenerationRequest() else { return }
        if case .sd = request.pipeline {
            do {
                _ = try await imageRepository.ensureOutputDirectory(
                    imageDir: request.imageDir
                )
            } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
                await generationService.updateStatus(
                    .error("Couldn't access images folder at: \(path)")
                )
                return
            } catch {
                await generationService.updateStatus(
                    .error("Couldn't access images folder.")
                )
                return
            }
        }

        await generationService.enqueue(request)
    }

    func setStartingImage(image: CGImage, filename: String? = nil) {
        startingImage = image
        startingImageFilename =
            normalizedFilename(filename) ?? consumePendingSelectedImageFilename()
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
        let imageFilename = normalizedFilename(filename) ?? consumePendingSelectedImageFilename()
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
        return normalizedFilename(pendingSelectedImageFilename)
    }

    private func normalizedFilename(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func copyToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        copyToPrompt(sdi)
    }

    func copyToPrompt(_ sdi: SDImage) {
        let metadataFields = imageGallery.metadataFields(for: sdi.id)

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
        guard let sdi = imageGallery.selected() else { return }
        configStore.prompt = sdi.prompt
    }

    func copyModelToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        setModel(sdi.model)
    }

    func setModel(_ modelName: String) {
        if let matchingModel = models.first(where: { $0.name == modelName }) {
            currentModelId = matchingModel.id
            return
        }
    }

    func copySizeToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
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
        guard let sdi = imageGallery.selected() else { return }
        configStore.negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = imageGallery.selected() else { return }
        configStore.guidanceScale = sdi.guidanceScale
    }

    private func buildGenerationRequest() -> GenerationRequest? {
        guard let model = currentModel else {
            return nil
        }
        guard let adapter = PipelineModelAdapter.from(model) else {
            logger.error("unknown model type")
            return nil
        }

        let size = CGSize(width: configStore.width, height: configStore.height)
        let targetImageSize = adapter.inputSize ?? size
        let startingImageData = startingImage?.scaledAndCroppedTo(size: targetImageSize)?.pngData()

        var controlNetInputs: [Data] = []
        var controlNets: [String] = []
        var controlNetImageNames: [String] = []
        if let inputSize = adapter.inputSize {
            for input in currentControlNets {
                guard
                    let name = input.name,
                    let image = input.image,
                    let data = image.scaledAndCroppedTo(size: inputSize)?.pngData()
                else { continue }

                controlNetInputs.append(data)
                controlNets.append(name)
                if let imageFilename = normalizedFilename(input.imageFilename) {
                    controlNetImageNames.append(imageFilename)
                }
            }
        }

        let pipeline: GenerationPipeline
        let startingImageName: String?
        let requestControlNetImageNames: [String]
        let inputImageNames: [String]
        switch adapter {
        case .sd:
            pipeline = adapter.makePipeline(configStore: configStore, controlNets: controlNets)
            startingImageName = normalizedFilename(startingImageFilename)
            requestControlNetImageNames = controlNetImageNames
            inputImageNames = []
        case .irisFluxKlein:
            pipeline = adapter.makePipeline(configStore: configStore, controlNets: [])
            startingImageName = nil
            requestControlNetImageNames = []
            inputImageNames = normalizedFilename(startingImageFilename).map { [$0] } ?? []
        }

        return GenerationRequest(
            pipeline: pipeline,
            prompt: configStore.prompt,
            negativePrompt: configStore.negativePrompt,
            size: size,
            startingImageData: startingImageData,
            startingImageName: startingImageName,
            controlNetInputs: controlNetInputs,
            controlNetImageNames: requestControlNetImageNames,
            inputImageNames: inputImageNames,
            strength: Float(configStore.strength),
            stepCount: Int(configStore.steps),
            guidanceScale: Float(configStore.guidanceScale),
            disableSafety: !configStore.safetyChecker,
            scheduler: configStore.scheduler,
            useDenoisedIntermediates: configStore.showGenerationPreview,
            seed: seed == 0 ? UInt32.random(in: 0..<UInt32.max) : seed,
            numberOfImages: Int(numberOfImages),
            imageDir: configStore.imageDir,
            imageType: configStore.imageType
        )
    }

    private func observeGenerationService() {
        generationUpdatesTask?.cancel()
        generationUpdatesTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.generationService.updates()
            for await snapshot in stream {
                self.apply(snapshot)
            }
        }
    }

    private func observeGenerationResults() {
        generationResultsTask?.cancel()
        generationResultsTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.generationService.results()
            for await result in stream {
                self.apply(result)
            }
        }
    }

    private func observeGenerationStatus() {
        generationStatusTask?.cancel()
        generationStatusTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.generationService.statusUpdates()
            for await status in stream {
                self.apply(status)
            }
        }
    }

    private func observeGenerationPreview() {
        generationPreviewTask?.cancel()
        generationPreviewTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.generationService.previewUpdates()
            for await image in stream {
                self.applyCurrentGeneratingImage(image)
            }
        }
    }

    private func apply(_ snapshot: GenerationService.Snapshot) {
        generationQueue = snapshot.queue
        currentGeneration = snapshot.current
    }

    private func apply(_ result: GenerationResult) {
        let shouldAnimateInsert = imageGallery.currentGeneratingImage == nil
        defer {
            imageGallery.setCurrentGenerating(image: nil)
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
            mlComputeUnit: metadata.pipeline.mlComputeUnit,
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
        imageGallery.add(
            sdi,
            metadataFields: metadata.metadataFields,
            animate: shouldAnimateInsert
        )
    }

    private func apply(_ status: GenerationState.Status) {
        generationState.state = status
    }

    private func applyCurrentGeneratingImage(_ image: CGImage?) {
        imageGallery.setCurrentGenerating(image: image)
    }

    func removeQueued(_ id: GenerationRequest.ID) async {
        await generationService.removeQueued(id: id)
    }

    func stopCurrentGeneration() async {
        await generationService.stopCurrentGeneration()
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
        modelFolderMonitor = nil
        let path = modelDirectoryPath()
        modelFolderMonitor = FolderMonitor(path: path) { [weak self] in
            Task { @MainActor in
                await self?.loadModels()
            }
        }
    }

    private func startControlNetFolderMonitor() {
        controlNetFolderMonitor = nil
        let path = controlNetDirectoryPath()
        controlNetFolderMonitor = FolderMonitor(path: path) { [weak self] in
            Task { @MainActor in
                await self?.loadModels()
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
