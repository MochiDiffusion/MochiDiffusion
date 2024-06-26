//
//  ImageController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import Foundation
import StableDiffusion
import SwiftUI
import UniformTypeIdentifiers
import os

typealias StableDiffusionProgress = StableDiffusionPipeline.Progress

enum ComputeUnitPreference: String {
    case auto
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all

    func computeUnits(forModel model: SDModel) -> MLComputeUnits {
        switch self {
        case .auto:
            return model.attention.preferredComputeUnits
        case .cpuAndGPU:
            return .cpuAndGPU
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        case .all:
            return .all
        }
    }
}

@MainActor
final class ImageController: ObservableObject {

    static let shared = ImageController()

    private lazy var logger = Logger()

    @Published
    var generationQueue = [GenerationConfig]()

    @Published
    var currentGeneration: GenerationConfig?

    @Published
    var isLoading = true

    @Published
    private(set) var models = [SDModel]()

    @Published
    var controlNet: [String] = []

    @Published
    var startingImage: CGImage?

    @Published
    var numberOfImages = 1.0

    @Published
    var seed: UInt32 = 0

    @Published
    var quicklookURL: URL? {
        didSet {
            /// When Quick Look is manually dismissed with its close button, the system will set this to nil.
            /// Propagate the change to quicklookId, but prevent infinite didSet loops.
            if quicklookURL == nil, oldValue != nil {
                quicklookId = nil
            }
        }
    }

    private var quicklookId: UUID? {
        didSet {
            quicklookURL = quicklookId.flatMap { id in
                try? ImageStore.shared.image(with: id)?.image?.asTransferableImage().image
                    .temporaryFileURL()
            }
        }
    }

    @Published
    var currentModel: SDModel? {
        didSet {
            guard let model = currentModel else {
                return
            }

            modelName = model.name
            controlNet = model.controlNet
            currentControlNets = []
        }
    }

    @Published
    private(set) var currentControlNets: [(name: String?, image: CGImage?)] = []

    @AppStorage("ModelDir") var modelDir = ""
    @AppStorage("ControlNetDir") var controlNetDir = ""
    @AppStorage("Model") private(set) var modelName = ""
    @AppStorage("AutosaveImages") var autosaveImages = true
    @AppStorage("ImageDir") var imageDir = ""
    @AppStorage("ImageType") var imageType = UTType.png.preferredFilenameExtension!
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("ImageStrength") var strength = 0.75
    @AppStorage("Steps") var steps = 12.0
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler: Scheduler = .dpmSolverMultistepScheduler
    @AppStorage("UpscaleGeneratedImages") var upscaleGeneratedImages = false
    @AppStorage("ShowGenerationPreview") var showGenerationPreview = true
    @AppStorage("MLComputeUnitPreference") var mlComputeUnitPreference: ComputeUnitPreference =
        .auto
    @AppStorage("ReduceMemory") var reduceMemory = false
    @AppStorage("SafetyChecker") var safetyChecker = false
    @AppStorage("UseTrash") var useTrash = true

    private var imageFolderMonitor: FolderMonitor?
    private var modelFolderMonitor: FolderMonitor?
    private var controlNetFolderMonitor: FolderMonitor?

    init() {
        Task {
            await load()
        }
        self.imageFolderMonitor = FolderMonitor(path: imageDir) {
            if let fileList = try? FileManager.default.contentsOfDirectory(atPath: self.imageDir) {
                var additions = [SDImage]()
                var removals = [SDImage]()
                for filePath in fileList {
                    if !ImageStore.shared.images.map({ URL(filePath: $0.path).lastPathComponent })
                        .contains(where: {
                            $0 == filePath
                        })
                    {
                        let fileURL = URL(filePath: self.imageDir).appending(component: filePath)
                        if let sdi = createSDImageFromURL(fileURL) {
                            additions.append(sdi)
                        }
                    }
                }
                for sdi in ImageStore.shared.images {
                    if !fileList.contains(where: {
                        sdi.path.isEmpty  // ignore images generated with autosave disabled
                            || $0 == URL(filePath: sdi.path).lastPathComponent
                    }) {
                        removals.append(sdi)
                    }
                }
                Task {
                    ImageStore.shared.add(additions)
                    ImageStore.shared.remove(removals)
                }
            }
        }
        self.modelFolderMonitor = FolderMonitor(path: modelDir) {
            Task {
                await self.loadModels()
            }
        }
        self.controlNetFolderMonitor = FolderMonitor(path: controlNetDir) {
            Task {
                await self.loadModels()
            }
        }
    }

    /// Run init sequence for ImageController
    func load() async {
        isLoading = true
        if autosaveImages {
            await loadImages()
        }
        await loadModels()
        isLoading = false
    }

    func loadImages() async {
        logger.info("Started loading image autosave directory at: \"\(self.imageDir)\"")
        /// If there are unautosaved images,
        /// keep those images in gallery while loading from autosave directory so we don't lose their work
        ImageStore.shared.removeAllExceptUnsaved()
        do {
            async let (images, imageDirURL) = try ImageGenerator.shared.loadImages(
                imageDir: imageDir)
            let count = try await images.count
            try await self.imageDir = imageDirURL.path(percentEncoded: false)

            logger.info("Found \(count) image(s)")

            try await ImageStore.shared.add(images)
        } catch ImageGenerator.GeneratorError.imageDirectoryNoAccess {
            logger.error("Couldn't access autosave directory.")
        } catch {
            logger.error("There was a problem loading the images: \(error.localizedDescription)")
        }
    }

    private func directoryURL(fromPath directory: String, defaultingTo string: String) -> URL {
        var finalModelDirURL: URL

        /// check if saved directory exists
        if directory.isEmpty {
            /// use default directory
            finalModelDirURL = FileManager.default.homeDirectoryForCurrentUser
            finalModelDirURL.append(path: string, directoryHint: .isDirectory)
        } else {
            /// generate url from saved directory
            finalModelDirURL = URL(fileURLWithPath: directory, isDirectory: true)
        }

        return finalModelDirURL
    }

    func loadModels() async {
        models = []
        logger.info("Started loading model directory at: \"\(self.modelDir)\"")
        do {
            let modelDirectoryURL = directoryURL(
                fromPath: modelDir, defaultingTo: "MochiDiffusion/models/")
            self.modelDir = modelDirectoryURL.path(percentEncoded: false)

            let controlNetDirectoryURL = directoryURL(
                fromPath: controlNetDir, defaultingTo: "MochiDiffusion/controlnet/")
            self.controlNetDir = controlNetDirectoryURL.path(percentEncoded: false)

            await self.models = try ImageGenerator.shared.getModels(
                modelDirectoryURL: modelDirectoryURL, controlNetDirectoryURL: controlNetDirectoryURL
            )

            logger.info("Found \(self.models.count) model(s)")

            /// Try restoring last user selected model
            /// If not found, use first model from list
            guard let model = self.models.first(where: { $0.name == modelName }) else {
                self.currentModel = self.models.first
                return
            }
            self.currentModel = model
        } catch ImageGenerator.GeneratorError.modelDirectoryNoAccess {
            logger.error("Couldn't access model directory.")
            modelName = ""
        } catch ImageGenerator.GeneratorError.modelSubDirectoriesNoAccess {
            logger.error("Could not get model subdirectories.")
            modelName = ""
        } catch ImageGenerator.GeneratorError.noModelsFound {
            logger.error("No models found.")
            modelName = ""
        } catch {
            modelName = ""
        }
    }

    func generate() async {
        guard let model = currentModel else {
            return
        }

        var pipelineConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
        pipelineConfig.negativePrompt = negativePrompt
        if let size = currentModel?.inputSize {
            pipelineConfig.startingImage = startingImage?.scaledAndCroppedTo(size: size)
        }
        pipelineConfig.strength = Float(strength)
        pipelineConfig.stepCount = Int(steps)
        pipelineConfig.seed = seed
        pipelineConfig.guidanceScale = Float(guidanceScale)
        pipelineConfig.disableSafety = !safetyChecker
        pipelineConfig.schedulerType = convertScheduler(scheduler)
        for controlNet in currentControlNets {
            if controlNet.name != nil, let size = currentModel?.inputSize,
                let image = controlNet.image?.scaledAndCroppedTo(size: size)
            {
                pipelineConfig.controlNetInputs.append(image)
            }
        }
        pipelineConfig.useDenoisedIntermediates = showGenerationPreview

        let genConfig = GenerationConfig(
            pipelineConfig: pipelineConfig,
            isXL: model.isXL,
            isSD3: model.isSD3,
            autosaveImages: autosaveImages,
            imageDir: imageDir,
            imageType: imageType,
            numberOfImages: Int(numberOfImages),
            model: model,
            mlComputeUnit: mlComputeUnitPreference.computeUnits(forModel: model),
            scheduler: scheduler,
            upscaleGeneratedImages: upscaleGeneratedImages,
            controlNets: currentControlNets.filter { $0.image != nil }.compactMap(\.name)
        )

        self.generationQueue.append(genConfig)
        Task.detached(priority: .high) {
            await self.runGenerationJobs()
        }
    }

    private func runGenerationJobs() async {
        guard case .ready = ImageGenerator.shared.state else { return }

        while !self.generationQueue.isEmpty {
            let genConfig = generationQueue.removeFirst()
            self.currentGeneration = genConfig
            do {
                try await ImageGenerator.shared.loadPipeline(
                    model: genConfig.model,
                    controlNet: genConfig.controlNets,
                    computeUnit: genConfig.mlComputeUnit,
                    reduceMemory: self.reduceMemory
                )
                try await ImageGenerator.shared.generate(genConfig)
            } catch ImageGenerator.GeneratorError.requestedModelNotFound {
                self.logger.error("Couldn't load \(genConfig.model.name) because it doesn't exist.")
                await ImageGenerator.shared.updateState(
                    .ready("Couldn't load \(genConfig.model.name) because it doesn't exist."))
            } catch ImageGenerator.GeneratorError.pipelineNotAvailable {
                self.logger.error("Pipeline is not available.")
                await ImageGenerator.shared.updateState(
                    .ready("There was a problem loading pipeline."))
            } catch PipelineError.startingImageProvidedWithoutEncoder {
                self.logger.error("The selected model does not support setting a starting image.")
                await ImageGenerator.shared.updateState(
                    .ready("The selected model does not support setting a starting image."))
            } catch Encoder.Error.sampleInputShapeNotCorrect {
                self.logger.error(
                    "The starting image size doesn't match the size of the image that will be generated."
                )
                await ImageGenerator.shared.updateState(
                    .ready(
                        "The starting image size doesn't match the size of the image that will be generated."
                    ))
            } catch {
                self.logger.error("There was a problem generating images: \(error)")
                await ImageGenerator.shared.updateState(
                    .error("There was a problem generating images: \(error)"))
            }
        }
        self.currentGeneration = nil
        Task.detached {
            await NotificationController.shared.sendQueueEmptyNotification()
        }
    }

    func upscale(_ sdi: SDImage) async {
        if !sdi.upscaler.isEmpty { return }

        /// Set upscaling animation
        var upscalingSDI = sdi
        upscalingSDI.isUpscaling = true
        ImageStore.shared.update(upscalingSDI)

        async let maybeSDI = Upscaler.shared.upscale(sdi: sdi)
        guard let upscaledSDI = await maybeSDI else { return }
        ImageStore.shared.update(upscaledSDI)
        /// If Quick Look is already open show selected image
        if quicklookId != nil {
            quicklookId = upscaledSDI.id
        }
    }

    func upscaleCurrentImage() async {
        guard let sdi = ImageStore.shared.selected() else { return }
        await upscale(sdi)
    }

    func quicklookCurrentImage() async {
        guard let sdi = ImageStore.shared.selected() else {
            quicklookId = nil
            return
        }

        guard sdi.id != quicklookId else {
            /// Close Quick Look if triggered for the same image
            quicklookId = nil
            return
        }

        quicklookId = sdi.id
    }

    func select(_ id: SDImage.ID) async {
        ImageStore.shared.select(id)
        FocusController.shared.removeAllFocus()

        /// If Quick Look is already open, show selected image
        if quicklookId != nil {
            quicklookId = id
        }
    }

    func selectPrevious() async {
        guard let previous = ImageStore.shared.imageBefore(ImageStore.shared.selectedId) else {
            return
        }
        await select(previous)
    }

    func selectNext() async {
        guard let next = ImageStore.shared.imageAfter(ImageStore.shared.selectedId) else {
            return
        }
        await select(next)
    }

    func removeImage(_ sdi: SDImage) async {
        if sdi.id == ImageStore.shared.selectedId {
            if let previous = ImageStore.shared.imageBefore(sdi.id, wrap: false) {
                /// Move selection to the left, if possible.
                await select(previous)
            } else if let next = ImageStore.shared.imageAfter(sdi.id, wrap: false) {
                /// When deleting the first image, move selection to the right.
                await select(next)
            } else {
                /// No next or previous image found: deleting the last image.
                quicklookId = nil
            }
        }

        ImageStore.shared.removeAndDelete(sdi, moveToTrash: useTrash)
    }

    func removeCurrentImage() async {
        guard let sdi = ImageStore.shared.selected() else { return }
        await removeImage(sdi)
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

    func importImages() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose generated images to import")
        panel.prompt = String(localized: "Import", comment: "OK button text for import image panel")
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return
        }

        let selectedURLs = panel.urls
        if selectedURLs.isEmpty { return }

        isLoading = true
        var sdis: [SDImage] = []
        var succeeded = 0
        var failed = 0

        for url in selectedURLs {
            var importedURL: URL
            do {
                importedURL = URL(fileURLWithPath: imageDir, isDirectory: true)
                importedURL.append(path: url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: importedURL)
            } catch {
                failed += 1
                continue
            }
            guard let sdi = createSDImageFromURL(importedURL) else {
                failed += 1
                continue
            }
            succeeded += 1
            sdis.append(sdi)
        }
        ImageStore.shared.add(sdis)
        isLoading = false

        let alert = NSAlert()
        alert.messageText = String(localized: "Imported \(succeeded) image(s)")
        if failed > 0 {
            alert.informativeText = String(
                localized:
                    "\(failed) image(s) were not imported. Only images generated by Mochi Diffusion 2.2 or later can be imported."
            )
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        await alert.beginSheetModal(for: NSApplication.shared.mainWindow!)
    }

    func saveAll() async {
        if ImageStore.shared.images.isEmpty { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to save all images")
        panel.prompt = String(localized: "Save")
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return
        }

        guard let selectedURL = panel.url else { return }
        let type = UTType.fromString(ImageController.shared.imageType)

        for (index, sdi) in ImageStore.shared.images.enumerated() {
            let count = index + 1
            let url = selectedURL.appending(path: sdi.filenameWithoutExtension(count: count))
            await sdi.save(url, type: type)
        }
    }

    func copyToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        copyToPrompt(sdi)
    }

    func copyToPrompt(_ sdi: SDImage) {
        prompt = sdi.prompt
        negativePrompt = sdi.negativePrompt
        steps = Double(sdi.steps)
        guidanceScale = sdi.guidanceScale
        width = sdi.width
        height = sdi.height
        seed = sdi.seed
        scheduler = sdi.scheduler
    }

    func copyPromptToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        prompt = sdi.prompt
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
        guidanceScale = sdi.guidanceScale
    }

    func copyImage(_ sdi: SDImage) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard let imageData = await sdi.imageData(.png) else { return }
        guard let image = NSImage(data: imageData) else { return }
        pasteboard.writeObjects([image])
    }
}

extension CGImage {
    func asTransferableImage() -> TransferableImage {
        TransferableImage(image: NSImage(cgImage: self, size: NSSize(width: width, height: height)))
    }
}
