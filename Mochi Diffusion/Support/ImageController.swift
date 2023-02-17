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
    var numberOfImages = 1

    @Published
    var seed: UInt32 = 0

    @Published
    var quicklookURL: URL?

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
            /// continue
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
            numberOfImages: numberOfImages,
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
        /// if quick look is already open show selected image
        if quicklookURL != nil {
            await quicklookCurrentImage()
        }
    }

    func upscaleCurrentImage() async {
        guard let sdi = ImageStore.shared.selected() else { return }
        await upscale(sdi)
    }

    func quicklookCurrentImage() async {
        guard let sdi = ImageStore.shared.selected(), let image = sdi.image else {
            quicklookURL = nil
            return
        }
        quicklookURL = try? image.asNSImage().temporaryFileURL()
    }

    func select(_ index: Int) async {
        ImageStore.shared.select(index)
        /// if quick look is already open show selected image
        if quicklookURL != nil {
            await quicklookCurrentImage()
        }
    }

    func select(_ id: SDImage.ID) async {
        guard let index = ImageStore.shared.images.firstIndex(where: { $0.id == id }) else { return }
        await select(index)
    }

    func selectPrevious() async {
        let curIndex = ImageStore.shared.selectedIndex()
        if curIndex == ImageStore.shared.images.startIndex { return }
        await select(curIndex - 1)
    }

    func selectNext() async {
        let curIndex = ImageStore.shared.selectedIndex()
        if curIndex == ImageStore.shared.images.endIndex - 1 { return }
        await select(curIndex + 1)
    }

    func removeImage(_ sdi: SDImage) async {
        guard let index = ImageStore.shared.index(for: sdi.id) else { return }
        let curIndex = ImageStore.shared.selectedIndex()
        ImageStore.shared.remove(sdi)
        if ImageStore.shared.images.isEmpty {
            quicklookURL = nil
            return
        }
        if index <= curIndex {
            if curIndex == ImageStore.shared.images.endIndex {
                await select(curIndex - 1)
            } else if curIndex == 0 {
                await select(0)
            } else if index == curIndex {
                await select(curIndex)
            }
        }
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
        var count = 1
        for sdi in ImageStore.shared.images {
            let url = selectedURL.appending(path: "\(String(sdi.prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(sdi.seed).png")
            guard let image = sdi.image else { return }
            guard let data = CFDataCreateMutable(nil, 0) else { return }
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return
            }
            let iptc = [
                kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                kCGImagePropertyIPTCCaptionAbstract: sdi.metadata(),
                kCGImagePropertyIPTCProgramVersion: "\(NSApplication.appVersion)"
            ]
            let meta = [kCGImagePropertyIPTCDictionary: iptc]
            CGImageDestinationAddImage(destination, image, meta as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            do {
                try (data as Data).write(to: url)
            } catch {
                NSLog("*** Error saving images: \(error)")
            }
            count += 1
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
}

extension CGImage {
    func asNSImage() -> NSImage {
        NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}
