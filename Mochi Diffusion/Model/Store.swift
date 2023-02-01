//
//  GeneratorStore.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import Combine
import CoreML
import Foundation
import os
import StableDiffusion
import SwiftUI
import UniformTypeIdentifiers

typealias Model = String

enum GeneratorStatus {
    case idle
    case ready
    case error(String)
    case loading
    case running(StableDiffusionProgress?)
}

final class GeneratorStore: ObservableObject {
    @Published var models = [String]()
    @Published var images = [SDImage]()
    @Published var selectedImageIndex = -1
    @Published var quicklookURL: URL?
    @Published var status: GeneratorStatus = .idle
    @Published var numberOfImages = 1
    @Published var seed: UInt32 = 0
    @Published var queueProgress = QueueProgress()
    @Published var searchText = ""
    @AppStorage("ModelDir") var modelDir = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 12.0
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
    @AppStorage("UpscaleGeneratedImages") var upscaleGeneratedImages = false
    #if arch(arm64)
    @AppStorage("MLComputeUnit") var mlComputeUnit: MLComputeUnits = .cpuAndNeuralEngine
    #else
    private var mlComputeUnit: MLComputeUnits = .cpuAndGPU
    #endif
    @AppStorage("ReduceMemory") var reduceMemory = false
    @AppStorage("SafetyChecker") var safetyChecker = false
    @AppStorage("Model") private var model = ""
    private var pipeline: Pipeline?
    private var progressSubscriber: Cancellable?
    private let logger = Logger()

    var currentModel: String {
        get {
            model
        }
        set {
            model = newValue
            Task {
                await loadModel(modelName: newValue)
            }
        }
    }

    var getSelectedImage: SDImage? {
        if selectedImageIndex == -1 {
            return nil
        }
        return images[selectedImageIndex]
    }

    init() {
        logger.info("Generator init")
        loadModels()
    }

    func loadModels() {
        logger.info("Started loading model directory at: \"\(self.modelDir)\"")
        models = []
        let fm = FileManager.default
        var finalModelDir: URL
        // check if saved model directory exists
        if modelDir.isEmpty {
            // use default model directory
            guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                model = ""
                status = .error("Couldn't access model directory.")
                return
            }
            finalModelDir = documentsDir
            finalModelDir.append(path: "MochiDiffusion/models/", directoryHint: .isDirectory)
        } else {
            // generate url from saved model directory
            finalModelDir = URL(fileURLWithPath: modelDir, isDirectory: true)
        }
        if !fm.fileExists(atPath: finalModelDir.path(percentEncoded: false)) {
            logger.notice("Creating models directory at: \"\(finalModelDir.path(percentEncoded: false))\"")
            try? fm.createDirectory(at: finalModelDir, withIntermediateDirectories: true)
        }
        modelDir = finalModelDir.path(percentEncoded: false)
        do {
            let subDirs = try finalModelDir.subDirectories()
            subDirs.forEach { dir in
                models.append(dir.lastPathComponent)
            }
        } catch {
            logger.notice("Could not get model subdirectories under: \"\(finalModelDir.path(percentEncoded: false))\"")
            status = .error("Could not get model subdirectories.")
            return
        }
        guard let firstModel = models.first else {
            self.model = ""
            status = .error("No models found under: \(finalModelDir.path(percentEncoded: false))")
            return
        }
        logger.info("Found \(self.models.count) model(s)")
        self.currentModel = model.isEmpty ? firstModel : model
    }

    @MainActor
    func loadModel(modelName: String) async {
        logger.info("Started loading model: \"\(modelName)\"")
        let dir = URL(fileURLWithPath: modelDir, isDirectory: true)
            .appending(component: modelName, directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            logger.info("Couldn't find model \"\(modelName)\" at: \"\(dir.path(percentEncoded: false))\"")
            self.model = ""
            models.removeAll { $0 == model }
            status = .error("Couldn't load \(modelName) because it doesn't exist.")
            return
        }
        logger.info("Found model: \"\(modelName)\"")
        let config = MLModelConfiguration()
        config.computeUnits = mlComputeUnit
        do {
            let pipeline = try StableDiffusionPipeline(
                resourcesAt: dir,
                configuration: config,
                disableSafety: true,
                reduceMemory: reduceMemory
            )
            logger.info("Stable Diffusion pipeline successfully loaded")
            DispatchQueue.main.async {
                self.model = modelName
                self.pipeline = Pipeline(pipeline)
                self.status = .ready
            }
        } catch {
            model = ""
            DispatchQueue.main.async {
                self.status = .error("There was a problem loading the model: \(modelName)")
            }
        }
    }

    func generate() {
        if case GeneratorStatus.ready = status {
            // continue
        } else {
            return
        }
        guard let pipeline = pipeline else {
            status = .error("Pipeline is not loaded.")
            return
        }
        status = .loading
        progressSubscriber = pipeline.progressPublisher.sink { progress in
            guard let progress = progress else { return }
            DispatchQueue.main.async {
                self.status = .running(progress)
            }
        }
        DispatchQueue.global(qos: .default).async {
            do {
                // Save settings used to generate
                let numberOfImages = self.numberOfImages
                let upscaleGeneratedImages = self.upscaleGeneratedImages
                let safetyChecker = self.safetyChecker
                var sdi = SDImage()
                sdi.prompt = self.prompt
                sdi.negativePrompt = self.negativePrompt
                sdi.model = self.currentModel
                sdi.scheduler = self.scheduler
                sdi.steps = Int(self.steps)
                sdi.guidanceScale = self.guidanceScale

                // Generate
                var seedUsed = self.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : self.seed
                for index in 0 ..< numberOfImages {
                    DispatchQueue.main.async {
                        self.queueProgress = QueueProgress(index: index, total: numberOfImages)
                    }
                    let (imgs, seed) = try pipeline.generate(
                        prompt: sdi.prompt,
                        negativePrompt: sdi.negativePrompt,
                        numInferenceSteps: sdi.steps,
                        seed: seedUsed,
                        guidanceScale: Float(sdi.guidanceScale),
                        disableSafety: !safetyChecker,
                        scheduler: sdi.scheduler
                    )
                    if pipeline.hasGenerationBeenStopped {
                        break
                    }
                    var simgs = [SDImage]()
                    for img in imgs {
                        sdi.id = UUID()
                        sdi.image = img
                        sdi.width = img.width
                        sdi.height = img.height
                        sdi.aspectRatio = CGFloat(Double(img.width) / Double(img.height))
                        sdi.seed = seed
                        sdi.generatedDate = Date.now
                        simgs.append(sdi)
                    }
                    if upscaleGeneratedImages {
                        self.upscaleThenAddImages(simgs: simgs)
                    } else {
                        self.addImages(simgs: simgs)
                    }
                    seedUsed += 1
                }
                self.progressSubscriber?.cancel()

                DispatchQueue.main.async {
                    self.status = .ready
                }
            } catch {
                self.logger.error("There was a problem generating images: \(error)")
                DispatchQueue.main.async {
                    self.status = .error("There was a problem generating images: \(error)")
                }
            }
        }
    }

    func stopGeneration() {
        pipeline?.stopGeneration()
    }

    func upscaleImage(sdi: SDImage) {
        DispatchQueue.global(qos: .default).async {
            if !sdi.upscaler.isEmpty { return }
            guard let index = self.images.firstIndex(where: { $0.id == sdi.id }) else { return }
            guard let upscaledImage = Upscaler.shared.upscale(sdi: sdi) else { return }
            DispatchQueue.main.async {
                self.images[index] = upscaledImage
                // If quicklook is already open show selected image
                if self.quicklookURL != nil {
                    self.quicklookCurrentImage()
                }
            }
        }
    }

    func upscaleCurrentImage() {
        guard let sdi = getSelectedImage else { return }
        upscaleImage(sdi: sdi)
    }

    func quicklookCurrentImage() {
        guard let sdi = getSelectedImage, let img = sdi.image else { return }
        quicklookURL = try? img.asNSImage().temporaryFileURL()
    }

    func selectImage(index: Int) {
        selectedImageIndex = index
        // If quicklook is already open show selected image
        if quicklookURL != nil {
            quicklookCurrentImage()
        }
    }

    func selectPreviousImage() {
        if selectedImageIndex == 0 { return }
        selectImage(index: selectedImageIndex - 1)
    }

    func selectNextImage() {
        if selectedImageIndex == images.count - 1 { return }
        selectImage(index: selectedImageIndex + 1)
    }

    func removeImage(index: Int) {
        images.remove(at: index)
        if index <= selectedImageIndex {
            if selectedImageIndex != 0 || images.isEmpty {
                selectImage(index: selectedImageIndex - 1)
            }
        }
    }

    func removeCurrentImage() {
        removeImage(index: selectedImageIndex)
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose generated images to import")
        panel.prompt = String(localized: "Import", comment: "Header text for import image open panel")
        let resp = panel.runModal()
        if resp != .OK {
            return
        }
        let selectedURLs = panel.urls
        if selectedURLs.isEmpty { return }

        var succeeded = 0, failed = 0

        for url in selectedURLs {
            guard let sdi = createSDImageFromURL(url: url) else {
                failed += 1
                continue
            }
            succeeded += 1
            images.append(sdi)
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Imported \(succeeded) image(s)")
        if failed > 0 {
            alert.informativeText = String(localized: "\(failed) image(s) were not imported. Only images generated by Mochi Diffusion 2.2 or later can be imported.")
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func saveAllImages() {
        if images.isEmpty { return }
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to save all images")
        panel.prompt = String(localized: "Save")
        let resp = panel.runModal()
        if resp != .OK {
            return
        }

        guard let selectedURL = panel.url else { return }
        var count = 1
        for sdi in images {
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
        guard let sdi = getSelectedImage else { return }
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
        guard let sdi = getSelectedImage else { return }
        prompt = sdi.prompt
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = getSelectedImage else { return }
        negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = getSelectedImage else { return }
        scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = getSelectedImage else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = getSelectedImage else { return }
        steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = getSelectedImage else { return }
        guidanceScale = sdi.guidanceScale
    }

    private func addImages(simgs: [SDImage]) {
        DispatchQueue.main.async {
            withAnimation(.default.speed(1.5)) {
                self.images.append(contentsOf: simgs)
            }
        }
    }

    private func upscaleThenAddImages(simgs: [SDImage]) {
        var upscaledSDImgs = [SDImage]()
        for sdi in simgs {
            guard let upscaledImage = Upscaler.shared.upscale(sdi: sdi) else { continue }
            upscaledSDImgs.append(upscaledImage)
        }
        DispatchQueue.main.async {
            self.addImages(simgs: upscaledSDImgs)
        }
    }
}
