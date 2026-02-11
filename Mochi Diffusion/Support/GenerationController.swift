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
    private var logger = Logger()
    private(set) var configStore: ConfigStore
    private let modelRepository: ModelRepository
    private let imageRepository: ImageRepository
    private(set) var generationQueue = [GenerationRequest]()
    private(set) var currentGeneration: GenerationRequest?
    private(set) var models = [any MochiModel]()
    private(set) var controlNet: [String] = []
    var startingImage: CGImage?
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

    private(set) var currentControlNets: [(name: String?, image: CGImage?)] = []

    private var modelFolderMonitorTask: Task<Void, Never>?
    private var controlNetFolderMonitorTask: Task<Void, Never>?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var controlNetDirDebounceTask: Task<Void, Never>?
    private var generationUpdatesTask: Task<Void, Never>?
    private var generationResultsTask: Task<Void, Never>?

    init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository()
    ) {
        self.configStore = configStore
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
            await GenerationService.shared.updateStatus(
                .error("Could not get model subdirectories.")
            )
            configStore.modelId = nil
        } catch SDImageGenerator.GeneratorError.noModelsFound {
            logger.error("No models found.")
            await GenerationService.shared.updateStatus(
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
        }

        await GenerationService.shared.enqueue(request)
    }

    func setStartingImage(image: CGImage) {
        startingImage = image
    }

    func selectStartingImage() async {
        startingImage = await selectImage()
    }

    func selectStartingImage(sdi: SDImage) async {
        guard let image = sdi.image else { return }
        startingImage = image
    }

    func unsetStartingImage() async {
        startingImage = nil
    }

    func setControlNet(name: String) async {
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [(name: name, image: nil)]
        } else {
            self.currentControlNets[0].name = name
        }
    }

    func setControlNet(image: CGImage) async {
        if self.currentControlNets.isEmpty {
            self.currentControlNets = [(name: nil, image: image)]
        } else {
            self.currentControlNets[0].image = image
        }
    }

    func unsetControlNet() async {
        self.currentControlNets = []
    }

    func selectControlNetImage(at index: Int) async {
        await selectImage().map { image in
            if currentControlNets.isEmpty {
                currentControlNets = [(name: nil, image: image)]
            } else if index >= currentControlNets.count {
                currentControlNets.append((name: nil, image: image))
            } else {
                currentControlNets[index].image = image
            }
        }
    }

    func unsetControlNetImage(at index: Int) async {
        guard index < currentControlNets.count else { return }
        currentControlNets[index].image = nil
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

        return CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil)
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

    private func buildGenerationRequest() -> GenerationRequest? {
        guard let model = currentModel else {
            return nil
        }

        let size = CGSize(width: configStore.width, height: configStore.height)
        var startingImageData: Data?
        if let inputSize = (model as? SDModel)?.inputSize {
            startingImageData = self.startingImage?.scaledAndCroppedTo(size: inputSize)?.pngData()
        } else {
            startingImageData = self.startingImage?.scaledAndCroppedTo(size: size)?.pngData()
        }

        var controlNetInputs: [Data] = []
        var controlNets: [String] = []
        for controlNet in currentControlNets {
            guard
                let name = controlNet.name,
                let image = controlNet.image,
                let inputSize = (model as? SDModel)?.inputSize,
                let data = image.scaledAndCroppedTo(size: inputSize)?.pngData()
            else { continue }
            controlNetInputs.append(data)
            controlNets.append(name)
        }

        let pipeline: GenerationPipeline
        switch type(of: model) {
        case is SDModel.Type:
            let model = model as! SDModel
            pipeline = GenerationPipeline.sd(
                model: model,
                computeUnit: configStore.mlComputeUnitPreference.computeUnits(forModel: model),
                controlNets: controlNets,
                reduceMemory: configStore.reduceMemory
            )
        case is Flux2cModel.Type:
            pipeline = GenerationPipeline.flux2c(
                modelDir: model.url.path(percentEncoded: false)
            )

        default:
            logger.error("unknown model type")
            return nil
        }

        return GenerationRequest(
            pipeline: pipeline,
            prompt: configStore.prompt,
            negativePrompt: configStore.negativePrompt,
            size: size,
            startingImageData: startingImageData,
            controlNetInputs: controlNetInputs,
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
        ImageGallery.shared.add(sdi, metadataFields: metadata.metadataFields)
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
