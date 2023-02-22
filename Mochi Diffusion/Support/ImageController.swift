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

@MainActor
final class ImageController: ObservableObject {

    static let shared = ImageController()

    private lazy var logger = Logger()

    @Published
    private(set) var models = [SDModel]()

    @Published
    var numberOfImages = 1.0

    @Published
    var seed: UInt32 = 0

    @Published
    var quicklookURL: URL? {
        didSet {
            // When Quick Look is manually dismissed with its close button, the system will set this to nil.
            // Propagate the change to quicklookId, but prevent infinite didSet loops.
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

    @AppStorage("ModelDir") var modelDir = ""
    @AppStorage("Model") private(set) var modelName = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 12.0
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler: Scheduler = .dpmSolverMultistepScheduler
    @AppStorage("UpscaleGeneratedImages") var upscaleGeneratedImages = false
    #if arch(arm64)
    @AppStorage("MLComputeUnit") var mlComputeUnit: MLComputeUnits = .cpuAndNeuralEngine
    #else
    private let mlComputeUnit: MLComputeUnits = .cpuAndGPU
    #endif
    @AppStorage("ReduceMemory") var reduceMemory = false
    @AppStorage("SafetyChecker") var safetyChecker = false

    @Published
    var currentModel: SDModel? {
        didSet {
            guard let model = currentModel else {
                return
            }
            modelName = model.name
            Task {
                do {
                    try await ImageGenerator.shared.load(
                        model: model,
                        computeUnit: mlComputeUnit,
                        reduceMemory: reduceMemory
                    )
                } catch {
                    modelName = ""
                    currentModel = nil
                }
            }
        }
    }

    init() {
        Task {
            logger.info("Generator init")
            await loadModels()
        }
    }

    func loadModels() async {
        models = []
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
        } catch {
            modelName = ""
        }
    }

    func generate() async {
        if case .ready = ImageGenerator.shared.state {
            // continue
        } else {
            return
        }

        var pipelineConfig = StableDiffusionPipeline.Configuration(prompt: prompt)
        pipelineConfig.negativePrompt = negativePrompt
        pipelineConfig.stepCount = Int(steps)
        pipelineConfig.seed = seed
        pipelineConfig.guidanceScale = Float(guidanceScale)
        pipelineConfig.disableSafety = !safetyChecker
        pipelineConfig.schedulerType = convertScheduler(scheduler)

        let genConfig = GenerationConfig(
            pipelineConfig: pipelineConfig,
            numberOfImages: Int(numberOfImages),
            model: modelName,
            mlComputeUnit: mlComputeUnit,
            scheduler: scheduler,
            upscaleGeneratedImages: upscaleGeneratedImages
        )

        Task.detached(priority: .high) {
            do {
                try await ImageGenerator.shared.generate(genConfig)
            } catch ImageGenerator.GeneratorError.pipelineNotAvailable {
                await self.logger.error("Pipeline is not loaded.")
            } catch {
                await self.logger.error("There was a problem generating images: \(error)")
            }
        }
    }

    func upscale(_ sdi: SDImage) async {
        if !sdi.upscaler.isEmpty { return }

        async let maybeSDI = Upscaler.shared.upscale(sdi: sdi)
        guard let upscaledSDI = await maybeSDI else { return }
        ImageStore.shared.update(upscaledSDI)
        // If Quick Look is already open show selected image
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
            // Close Quick Look if triggered for the same image
            quicklookId = nil
            return
        }

        quicklookId = sdi.id
    }

    func select(_ id: SDImage.ID) async {
        ImageStore.shared.select(id)

        // If Quick Look is already open, show selected image
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
        if let previous = ImageStore.shared.imageBefore(sdi.id, wrap: false) {
            // Move selection to the left, if possible.
            await select(previous)
        } else if let next = ImageStore.shared.imageAfter(sdi.id, wrap: false) {
            // When deleting the first image, move selection to the right.
            await select(next)
        } else {
            // No next or previous image found: deleting the last image.
            quicklookId = nil
        }

        ImageStore.shared.remove(sdi)
    }

    func removeCurrentImage() async {
        guard let sdi = ImageStore.shared.selected() else { return }
        await removeImage(sdi)
    }

    func importImages() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose generated images to import")
        panel.prompt = String(localized: "Import", comment: "Header text for import image open panel")
        let resp = await panel.beginSheetModal(for: NSApplication.shared.mainWindow!)
        if resp != .OK {
            return
        }

        let selectedURLs = panel.urls
        if selectedURLs.isEmpty { return }

        var sdis: [SDImage] = []
        var succeeded = 0, failed = 0

        for url in selectedURLs {
            guard let sdi = createSDImageFromURL(url) else {
                failed += 1
                continue
            }
            succeeded += 1
            sdis.append(sdi)
        }
        ImageStore.shared.add(sdis)

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

        for (index, sdi) in ImageStore.shared.images.enumerated() {
            let count = index + 1
            let url = selectedURL.appending(path: "\(String(sdi.prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(sdi.seed).png")

            guard let data = await sdi.imageData(.png) else {
                NSLog("*** Failed to convert image")
                continue
            }

            do {
                try data.write(to: url)
            } catch {
                NSLog("*** Error saving images: \(error)")
            }
        }
    }

    func copyToPrompt() {
        guard let sdi = ImageStore.shared.selected() else { return }
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

    func copyImage() async {
        guard let sdi = ImageStore.shared.selected(),
            let imageData = await sdi.imageData(.png),
            let image = NSImage(data: imageData) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}

extension CGImage {
    func asNSImage() -> NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}
