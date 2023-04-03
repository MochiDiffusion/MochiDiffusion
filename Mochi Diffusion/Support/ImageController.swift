//
//  ImageController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import CoreML
import Foundation
import os
import StableDiffusion
import SwiftUI
import UniformTypeIdentifiers

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
    var isLoading = true

    @Published
    private(set) var models = [SDModel]()

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
                try? ImageStore.shared.image(with: id)?.image?.asNSImage().temporaryFileURL()
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
            Task {
                logger.info("Started loading model: \"\(self.modelName)\"")
                do {
                    try await ImageGenerator.shared.load(
                        model: model,
                        computeUnit: mlComputeUnitPreference.computeUnits(forModel: model),
                        reduceMemory: reduceMemory
                    )
                    logger.info("Stable Diffusion pipeline successfully loaded")
                } catch ImageGenerator.GeneratorError.requestedModelNotFound {
                    logger.error("Couldn't load \(self.modelName) because it doesn't exist.")
                    modelName = ""
                    currentModel = nil
                } catch {
                    modelName = ""
                    currentModel = nil
                }
            }
        }
    }

    @AppStorage("ModelDir") var modelDir = ""
    @AppStorage("Model") private(set) var modelName = ""
    @AppStorage("AutosaveImages") var autosaveImages = true
    @AppStorage("ImageDir") var imageDir = ""
    @AppStorage("ImageType") var imageType = UTType.png.preferredFilenameExtension!
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("ImageStrength") var strength = 0.7
    @AppStorage("Steps") var steps = 12.0
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler: Scheduler = .dpmSolverMultistepScheduler
    @AppStorage("UpscaleGeneratedImages") var upscaleGeneratedImages = false
    @AppStorage("MLComputeUnitPreference") var mlComputeUnitPreference: ComputeUnitPreference = .auto
    @AppStorage("ReduceMemory") var reduceMemory = false
    @AppStorage("SafetyChecker") var safetyChecker = false
    @AppStorage("UseTrash") var useTrash = true

    init() {
        Task {
            await load()
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
            async let (images, imageDirURL) = try ImageGenerator.shared.loadImages(imageDir: imageDir)
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

    func loadModels() async {
        models = []
        logger.info("Started loading model directory at: \"\(self.modelDir)\"")
        do {
            async let (foundModels, modelDirURL) = try ImageGenerator.shared.getModels(modelDir: modelDir)
            try await self.models = foundModels
            try await self.modelDir = modelDirURL.path(percentEncoded: false)

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
        guard case .ready = ImageGenerator.shared.state,
            let model = currentModel else {
            return
        }

        var pipelineConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
        pipelineConfig.negativePrompt = negativePrompt
        pipelineConfig.startingImage = startingImage
        pipelineConfig.strength = Float(strength)
        pipelineConfig.stepCount = Int(steps)
        pipelineConfig.seed = seed
        pipelineConfig.guidanceScale = Float(guidanceScale)
        pipelineConfig.disableSafety = !safetyChecker
        pipelineConfig.schedulerType = convertScheduler(scheduler)

        let genConfig = GenerationConfig(
            pipelineConfig: pipelineConfig,
            autosaveImages: autosaveImages,
            imageDir: imageDir,
            imageType: imageType,
            numberOfImages: Int(numberOfImages),
            model: modelName,
            mlComputeUnit: mlComputeUnitPreference.computeUnits(forModel: model),
            scheduler: scheduler,
            upscaleGeneratedImages: upscaleGeneratedImages
        )

        Task.detached(priority: .high) {
            do {
                try await ImageGenerator.shared.generate(genConfig)
            } catch ImageGenerator.GeneratorError.pipelineNotAvailable {
                await self.logger.error("Pipeline is not loaded.")
            } catch StableDiffusionPipeline.Error.startingImageProvidedWithoutEncoder {
                await self.logger.error("The selected model does not support setting a starting image.")
                await ImageGenerator.shared.updateState(.ready("The selected model does not support setting a starting image."))
            } catch Encoder.Error.sampleInputShapeNotCorrect {
                await self.logger.error("The starting image size doesn't match the size of the image that will be generated.")
                await ImageGenerator.shared.updateState(.ready("The starting image size doesn't match the size of the image that will be generated."))
            } catch {
                await self.logger.error("There was a problem generating images: \(error)")
                await ImageGenerator.shared.updateState(.error("There was a problem generating images: \(error)"))
            }
        }
    }

    func upscale(_ sdi: SDImage) async {
        if !sdi.upscaler.isEmpty { return }

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

    func selectStartingImage() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose starting image")
        panel.prompt = String(localized: "Select", comment: "OK button text for choose starting image panel")
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return
        }

        guard let url = panel.url else { return }
        guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
        guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else { return }
        if cgImage.width != 512 || cgImage.height != 512 {
            let alert = NSAlert()
            alert.messageText = String(localized: "Incorrect image size")
            alert.informativeText = String(localized: "Starting image must be 512x512.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            await alert.beginSheetModal(for: NSApplication.shared.mainWindow!)
            return
        }
        startingImage = cgImage
    }

    func selectStartingImage(sdi: SDImage) async {
        guard let image = sdi.image else { return }
        if image.width != 512 || image.height != 512 {
            let alert = NSAlert()
            alert.messageText = String(localized: "Incorrect image size")
            alert.informativeText = String(localized: "Starting image must be 512x512.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            await alert.beginSheetModal(for: NSApplication.shared.mainWindow!)
            return
        }
        startingImage = image
    }

    func unsetStartingImage() async {
        startingImage = nil
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
        var succeeded = 0, failed = 0

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
            alert.informativeText = String(localized: "\(failed) image(s) were not imported. Only images generated by Mochi Diffusion 2.2 or later can be imported.")
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
    func asNSImage() -> NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}
