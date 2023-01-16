//
//  Store.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//
// swiftlint:disable type_body_length file_length
import Foundation
import SwiftUI
import CoreML
import Combine
import StableDiffusion
import UniformTypeIdentifiers

final class Store: ObservableObject {
    @Published var pipeline: Pipeline?
    @Published var upscaler = Upscaler()
    @Published var models = [String]()
    @Published var images = [SDImage]()
    @Published var selectedImageIndex = -1 // TODO: replace with selectedItemIds
    @Published var selectedItemIds = Set<UUID>()
    @Published var quicklookURL: URL?
    @Published var mainViewStatus: MainViewStatus = .idle
    @Published var numberOfImages = 1
    @Published var seed: UInt32 = 0
    @Published var generationProgress = GenerationProgress()
    @Published var searchText = ""
    @AppStorage("WorkingDir") var workingDir = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 28
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
    @AppStorage("Model") private var model = ""
    private var progressSubscriber: Cancellable?

    var currentModel: String {
        get {
            return model
        }
        set {
            NSLog("*** Model set")
            model = newValue
            Task {
                NSLog("*** Loading model")
                await loadModel(model: newValue)
            }
        }
    }

    var getSelectedItems: [SDImage]? {
        if selectedItemIds.count == 0 {
            return []
        }
        return images.filter { selectedItemIds.contains($0.id) }
    }

    var getSelectedImage: SDImage? {
        if selectedImageIndex == -1 {
            return nil
        }
        return images[selectedImageIndex]
    }

    init() {
        NSLog("*** AppState initialized")
        loadModels()
    }

    func loadModels() {
        var dir: URL
        let appDir = "MochiDiffusion/models/"
        models = []
        if workingDir.isEmpty {
            guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                self.model = ""
                mainViewStatus = .error("Could not get working directory")
                return
            }
            dir = docDir
            dir.append(path: appDir, directoryHint: .isDirectory)
        } else {
            dir = URL(fileURLWithPath: workingDir, isDirectory: true)
            if !dir.path(percentEncoded: false).hasSuffix(appDir) {
                dir.append(path: appDir, directoryHint: .isDirectory)
            }
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            NSLog("Models directory does not exist at: \(dir.path). Creating ...")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        workingDir = dir.path(percentEncoded: false)
        // Find models in model dir
        do {
            let subs = try dir.subDirectories()
            subs.forEach { sub in
                models.append(sub.lastPathComponent)
            }
        } catch {
            self.model = ""
            mainViewStatus = .error("Could not get sub-folders under model directory: \(dir.path)")
            return
        }
        NSLog("*** Setting model")
        guard let firstModel = models.first else {
            self.model = ""
            mainViewStatus = .error("No models found under model directory: \(dir.path)")
            return
        }
        self.currentModel = model.isEmpty ? firstModel : model
    }

    @MainActor
    func loadModel(model: String) async {
        NSLog("*** Loading model: \(model)")
        let dir = URL(
            fileURLWithPath: workingDir,
            isDirectory: true
        ).appending(
            component: model,
            directoryHint: .isDirectory
        )
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            let msg = "Model \(model) does not exist at: \(dir.path)"
            NSLog(msg)
            self.model = ""
            models.removeAll { $0 == model }
            mainViewStatus = .error(msg)
            return
        }
        let beginDate = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = mlComputeUnit
        do {
            let pipeline = try StableDiffusionPipeline(
                resourcesAt: dir,
                configuration: configuration,
                disableSafety: true,
                reduceMemory: reduceMemory)
            NSLog("Pipeline loaded in \(Date().timeIntervalSince(beginDate))")
            DispatchQueue.main.async {
                self.pipeline = Pipeline(pipeline)
                self.mainViewStatus = .ready("Ready")
            }
        } catch {
            NSLog("Error loading model: \(error)")
            self.model = ""
            DispatchQueue.main.async {
                self.mainViewStatus = .error(error.localizedDescription)
            }
        }
    }

    func generate() {
        if case .loading = mainViewStatus { return }
        if case .running = mainViewStatus { return }
        guard let pipeline = pipeline else {
            mainViewStatus = .error("No pipeline available!")
            return
        }
        mainViewStatus = .loading
        // Pipeline progress subscriber
        progressSubscriber = pipeline.progressPublisher.sink { progress in
            guard let progress = progress else { return }
            DispatchQueue.main.async {
                self.mainViewStatus = .running(progress)
            }
        }
        DispatchQueue.global(qos: .default).async {
            do {
                // Save settings used to generate
                let numberOfImages = self.numberOfImages
                var sdi = SDImage()
                sdi.prompt = self.prompt
                sdi.negativePrompt = self.negativePrompt
                sdi.model = self.currentModel
                sdi.scheduler = self.scheduler
                sdi.steps = self.steps
                sdi.guidanceScale = self.guidanceScale

                // Generate
                var seedUsed = self.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : self.seed
                for index in 0 ..< numberOfImages {
                    DispatchQueue.main.async {
                        self.generationProgress = GenerationProgress(index: index, total: numberOfImages)
                    }
                    let (imgs, seed) = try pipeline.generate(
                        prompt: sdi.prompt,
                        negativePrompt: sdi.negativePrompt,
                        numInferenceSteps: sdi.steps,
                        seed: seedUsed,
                        guidanceScale: Float(sdi.guidanceScale),
                        scheduler: sdi.scheduler)
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
                    DispatchQueue.main.async {
                        if self.upscaleGeneratedImages {
                            self.upscaleThenAddImages(simgs: simgs)
                        } else {
                            self.addImages(simgs: simgs)
                        }
                    }
                    seedUsed += 1
                }
                self.progressSubscriber?.cancel()

                DispatchQueue.main.async {
                    self.mainViewStatus = .ready("Image generation complete")
                }
            } catch {
                let msg = "Error generating images: \(error)"
                NSLog(msg)
                DispatchQueue.main.async {
                    self.mainViewStatus = .error(msg)
                }
            }
        }
    }

    func stopGeneration() {
        pipeline?.stopGeneration()
    }

    func upscaleImage(sdImage: SDImage) {
        if sdImage.isUpscaled { return }
        guard let img = sdImage.image else { return }
        guard let upscaledImage = upscaler.upscale(cgImage: img) else { return }
        let newImageIndex = images.count
        var sdi = sdImage
        sdi.image = upscaledImage
        sdi.width = upscaledImage.width
        sdi.height = upscaledImage.height
        sdi.aspectRatio = CGFloat(Double(sdi.width) / Double(sdi.height))
        sdi.isUpscaled = true
        sdi.generatedDate = Date.now
        images.append(sdi)
        selectImage(index: newImageIndex)
    }

    func upscaleCurrentImage() {
        guard var sdi = getSelectedImage, let img = sdi.image else { return }
        if sdi.isUpscaled { return }

        guard let upscaledImage = upscaler.upscale(cgImage: img) else { return }
        let newImageIndex = images.count
        sdi.image = upscaledImage
        sdi.width = upscaledImage.width
        sdi.height = upscaledImage.height
        sdi.aspectRatio = CGFloat(Double(sdi.width) / Double(sdi.height))
        sdi.isUpscaled = true
        sdi.generatedDate = Date.now
        images.append(sdi)
        selectImage(index: newImageIndex)
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
            if selectedImageIndex != 0 || images.count == 0 {
                selectImage(index: selectedImageIndex - 1)
            }
        }
    }

    func removeCurrentImage() {
        removeImage(index: selectedImageIndex)
    }

    func saveAllImages() {
        if images.count == 0 { return }
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder to save all images"
        panel.prompt = "Save"
        let resp = panel.runModal()
        if resp != .OK {
            return
        }

        guard let selectedURL = panel.url else { return }
        var count = 1
        for sdi in images {
            // swiftlint:disable:next line_length
            let url = selectedURL.appending(path: "\(String(prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(sdi.seed).png")
            guard let image = sdi.image else { return }
            guard let data = CFDataCreateMutable(nil, 0) else { return }
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil) else { return }
            let iptc = [
                kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                kCGImagePropertyIPTCCaptionAbstract: sdi.metadata(),
                kCGImagePropertyIPTCProgramVersion: "\(NSApplication.appVersion)"]
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
        steps = sdi.steps
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
        steps = sdi.steps
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = getSelectedImage else { return }
        guidanceScale = sdi.guidanceScale
    }

    @MainActor
    private func addImages(simgs: [SDImage]) {
//        let newImageIndex = self.images.count
        withAnimation(.default.speed(1.5)) {
            self.images.append(contentsOf: simgs)
        }
//        self.selectImage(index: newImageIndex)
    }

    @MainActor
    private func upscaleThenAddImages(simgs: [SDImage]) {
        var upscaledSDImgs = [SDImage]()
        for simg in simgs {
            guard let image = simg.image else { continue }
            guard let upscaledImage = upscaler.upscale(cgImage: image) else { continue }
            var sdi = simg
            sdi.image = upscaledImage
            sdi.width = upscaledImage.width
            sdi.height = upscaledImage.height
            sdi.aspectRatio = CGFloat(Double(sdi.width) / Double(sdi.height))
            sdi.isUpscaled = true
            upscaledSDImgs.append(sdi)
        }
        self.addImages(simgs: upscaledSDImgs)
    }
}
