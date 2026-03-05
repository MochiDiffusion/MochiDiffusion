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

    struct InputImageInput {
        var image: CGImage
        var imageFilename: String?
        var edit: IrisReferenceImageEdit = .identity
    }

    private var logger = Logger()
    private(set) var configStore: ConfigStore
    private let modelRepository: ModelRepository
    private let imageRepository: ImageRepository
    private let loraNotesStore: LoraNotesStore
    private let generationService: GenerationService
    private let generationState: GenerationState
    private let imageGallery: ImageGallery
    private(set) var generationQueue = [GenerationRequest]()
    private(set) var currentGeneration: GenerationRequest?
    private(set) var models = [any MochiModel]()
    private(set) var loras: [String] = []
    private(set) var controlNet: [String] = []
    var startingImage: CGImage?
    var startingImageFilename: String?
    let maxInputImageCount = 5
    private(set) var currentInputImages: [InputImageInput] = []
    private(set) var loraNotes: [String: String] = [:]
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

    var irisReferenceBudgetReport: IrisReferenceBudgetReport? {
        guard let model = currentModel as? IrisFluxKleinModel else { return nil }

        let references = currentInputImages.prefix(maxInputImageCount).map { input in
            return IrisReferenceImageProcessor.editedPixelSize(
                for: input.image,
                edit: input.edit
            )
        }

        guard !references.isEmpty else { return nil }
        let outputSize = CGSize(width: configStore.width, height: configStore.height)
        return IrisReferenceBudgetEstimator.estimate(
            numHeads: model.attentionHeadCount,
            outputSize: outputSize,
            referenceSizes: references
        )
    }

    var currentLora: String? {
        didSet {
            configStore.loraName = normalizedLoraName(currentLora) ?? ""
        }
    }

    var currentLoraNote: String {
        guard let currentLora else { return "" }
        return loraNotes[currentLora, default: ""]
    }

    var currentLoraHasNote: Bool {
        !currentLoraNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private(set) var currentControlNets: [ControlNetInput] = []
    private var pendingSelectedImageFilename: String?

    private var modelFolderMonitor: FolderMonitor?
    private var loraFolderMonitor: FolderMonitor?
    private var controlNetFolderMonitor: FolderMonitor?
    private var modelDirDebounceTask: Task<Void, Never>?
    private var loraDirDebounceTask: Task<Void, Never>?
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
        imageRepository: ImageRepository = ImageRepository(),
        loraNotesStore: LoraNotesStore = LoraNotesStore()
    ) {
        self.configStore = configStore
        self.generationService = generationService
        self.generationState = generationState
        self.imageGallery = imageGallery
        self.modelRepository = modelRepository
        self.imageRepository = imageRepository
        self.loraNotesStore = loraNotesStore
        Task {
            await loadModels()
            loadLoras()
        }
        startModelFolderMonitor()
        startLoraFolderMonitor()
        startControlNetFolderMonitor()
        observeModelDir()
        observeLoraDir()
        observeControlNetDir()
        observeGenerationService()
        observeGenerationResults()
        observeGenerationStatus()
        observeGenerationPreview()
    }

    convenience init(
        configStore: ConfigStore,
        modelRepository: ModelRepository = ModelRepository(),
        imageRepository: ImageRepository = ImageRepository(),
        loraNotesStore: LoraNotesStore = LoraNotesStore()
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
            imageRepository: imageRepository,
            loraNotesStore: loraNotesStore
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

    func loadLoras() {
        let directoryURL = ModelRepository.loraDirectoryURL(fromPath: configStore.loraDir)
        logger.info(
            "Started loading LoRA directory at: \"\(directoryURL.path(percentEncoded: false))\""
        )

        let loadedLoras = loadLoraFiles(from: directoryURL)
        loraNotes = loraNotesStore.load()
        loras = loadedLoras

        if let savedLoraName = normalizedLoraName(configStore.loraName),
            loras.contains(savedLoraName)
        {
            currentLora = savedLoraName
        } else {
            currentLora = nil
        }
    }

    func setCurrentLoraNote(_ note: String) {
        guard let currentLora else { return }
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            loraNotes.removeValue(forKey: currentLora)
        } else {
            loraNotes[currentLora] = note
        }
        persistLoraNotes()
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

    func setInputImage(image: CGImage, at index: Int = 0, filename: String? = nil) {
        setInputImages([(image: image, filename: filename)], startingAt: index)
    }

    func setInputImages(
        _ images: [(image: CGImage, filename: String?)],
        startingAt index: Int = 0
    ) {
        guard index >= 0, index < maxInputImageCount else { return }
        guard index <= currentInputImages.count else { return }
        guard !images.isEmpty else { return }

        let assignableCount = min(images.count, maxInputImageCount - index)
        for offset in 0..<assignableCount {
            let targetIndex = index + offset
            let entry = images[offset]
            let imageFilename =
                normalizedFilename(entry.filename) ?? consumePendingSelectedImageFilename()
            let value = InputImageInput(
                image: entry.image,
                imageFilename: imageFilename,
                edit: .identity
            )

            if targetIndex == currentInputImages.count {
                currentInputImages.append(value)
            } else {
                currentInputImages[targetIndex] = value
            }
        }
    }

    func selectInputImage(at index: Int = 0) async {
        guard let image = await selectImage() else { return }
        setInputImage(image: image, at: index)
    }

    func unsetInputImage(at index: Int = 0) async {
        guard index < currentInputImages.count else { return }
        currentInputImages.remove(at: index)
    }

    func unsetInputImages() async {
        currentInputImages = []
    }

    func inputImageEdit(at index: Int) -> IrisReferenceImageEdit? {
        guard index >= 0, index < currentInputImages.count else { return nil }
        return currentInputImages[index].edit
    }

    func setInputImageEdit(_ edit: IrisReferenceImageEdit, at index: Int) {
        guard index >= 0, index < currentInputImages.count else { return }
        currentInputImages[index].edit = edit.clamped()
    }

    func resetInputImageEdit(at index: Int) {
        guard index >= 0, index < currentInputImages.count else { return }
        currentInputImages[index].edit = .identity
    }

    func editedInputImage(at index: Int) -> CGImage? {
        guard index >= 0, index < currentInputImages.count else { return nil }
        let input = currentInputImages[index]
        return IrisReferenceImageProcessor.applyEdits(
            to: input.image,
            edit: input.edit
        ) ?? input.image
    }

    func editedInputImageSize(at index: Int) -> CGSize? {
        guard index >= 0, index < currentInputImages.count else { return nil }
        let input = currentInputImages[index]
        return IrisReferenceImageProcessor.editedPixelSize(
            for: input.image,
            edit: input.edit
        )
    }

    func predictedInputImageSize(at index: Int) -> CGSize? {
        predictedIrisReferenceSize(at: index, in: irisReferenceBudgetReport)
    }

    func preprocessedInputImage(at index: Int) -> CGImage? {
        guard index >= 0, index < currentInputImages.count else { return nil }
        let input = currentInputImages[index]
        return preprocessedIrisInputImage(
            input,
            targetSize: predictedIrisReferenceSize(at: index, in: irisReferenceBudgetReport)
        )
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

    private func normalizedLoraName(_ loraName: String?) -> String? {
        guard let loraName else { return nil }
        let trimmed = loraName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func irisInputImageData(from image: CGImage) -> Data? {
        if let data = image.pngData() {
            return data
        }
        return image.normalizedRGBA8Image()?.pngData()
    }

    private func buildIrisInputImages() -> [(Data, String?)] {
        let activeInputs = Array(currentInputImages.prefix(maxInputImageCount))
        guard !activeInputs.isEmpty else { return [] }

        let budgetReport = irisReferenceBudgetReport
        return activeInputs.enumerated().compactMap { index, input in
            let preprocessed = preprocessedIrisInputImage(
                input,
                targetSize: predictedIrisReferenceSize(at: index, in: budgetReport)
            )

            guard let data = irisInputImageData(from: preprocessed) else { return nil }
            return (data, normalizedFilename(input.imageFilename))
        }
    }

    private func predictedIrisReferenceSize(
        at index: Int,
        in report: IrisReferenceBudgetReport?
    ) -> CGSize? {
        guard let report else { return nil }
        guard index >= 0, index < report.predictedReferenceSizes.count else { return nil }
        return report.predictedReferenceSizes[index]
    }

    private func preprocessedIrisInputImage(
        _ input: InputImageInput,
        targetSize: CGSize?
    ) -> CGImage {
        let edited =
            IrisReferenceImageProcessor.applyEdits(
                to: input.image,
                edit: input.edit
            ) ?? input.image

        guard let targetSize else { return edited }
        return
            IrisReferenceImageProcessor.resizedAndCroppedToTokenGrid(
                edited,
                to: targetSize
            ) ?? edited
    }

    private func loadLoraFiles(from directoryURL: URL) -> [String] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return
                contents
                .filter { !$0.hasDirectoryPath }
                .map(\.lastPathComponent)
                .sorted {
                    $0.compare($1, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedAscending
                }
        } catch {
            return []
        }
    }

    private func persistLoraNotes() {
        let normalizedNotes =
            loraNotes
            .compactMapValues { $0 }
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        loraNotes = normalizedNotes

        loraNotesStore.save(normalizedNotes)
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
        let startingImageData: Data?
        let startingImageName: String?
        let inputImageDatas: [Data]
        let requestControlNetImageNames: [String]
        let inputImageNames: [String]
        switch adapter {
        case .sd:
            let targetImageSize = adapter.inputSize ?? size
            pipeline = adapter.makePipeline(configStore: configStore, controlNets: controlNets)
            startingImageData = startingImage?.scaledAndCroppedTo(size: targetImageSize)?.pngData()
            startingImageName = normalizedFilename(startingImageFilename)
            inputImageDatas = []
            requestControlNetImageNames = controlNetImageNames
            inputImageNames = []
        case .irisFluxKlein:
            let inputs = buildIrisInputImages()
            if !currentInputImages.isEmpty, inputs.isEmpty {
                generationState.state = .error(
                    "Couldn't read input image. Convert it to a standard RGB PNG or JPEG and try again."
                )
                return nil
            }
            pipeline = adapter.makePipeline(configStore: configStore, controlNets: [])
            startingImageData = nil
            startingImageName = nil
            inputImageDatas = inputs.map(\.0)
            requestControlNetImageNames = []
            inputImageNames = inputs.compactMap(\.1)
        }

        return GenerationRequest(
            pipeline: pipeline,
            prompt: configStore.prompt,
            negativePrompt: configStore.negativePrompt,
            size: size,
            startingImageData: startingImageData,
            startingImageName: startingImageName,
            inputImageDatas: inputImageDatas,
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

    private func observeLoraDir() {
        withObservationTracking {
            _ = configStore.loraDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleLoraDirUpdate()
                self?.observeLoraDir()
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

    private func scheduleLoraDirUpdate() {
        loraDirDebounceTask?.cancel()
        loraDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateLoraFolderMonitor()
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

    private func updateLoraFolderMonitor() async {
        startLoraFolderMonitor()
        loadLoras()
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

    private func startLoraFolderMonitor() {
        loraFolderMonitor = nil
        let path = loraDirectoryPath()
        loraFolderMonitor = FolderMonitor(path: path) { [weak self] in
            Task { @MainActor in
                self?.loadLoras()
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

    private func loraDirectoryPath() -> String {
        ModelRepository.loraDirectoryURL(fromPath: configStore.loraDir)
            .path(percentEncoded: false)
    }

    private func controlNetDirectoryPath() -> String {
        ModelRepository.controlNetDirectoryURL(fromPath: configStore.controlNetDir)
            .path(percentEncoded: false)
    }
}
