//
//  Store.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import Foundation
import SwiftUI
import CoreML
import Combine
import StableDiffusion

final class Store: ObservableObject {
    @Published var pipeline: Pipeline? = nil
    @Published var upscaler = Upscaler()
    @Published var models = [String]()
    @Published var images = [SDImage]()
    @Published var selectedImageIndex = -1
    @Published var mainViewStatus: MainViewStatus = .loading
    @Published var numberOfBatches = 1
    @Published var batchSize = 1
    @Published var seed: UInt32 = 0
    @AppStorage("WorkingDir") var workingDir = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 28
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
    @AppStorage("UpscaleGeneratedImages") var upscaleGeneratedImages = false
    @AppStorage("MLComputeUnit") var mlComputeUnit: MLComputeUnits = .cpuAndNeuralEngine
    @AppStorage("ReduceMemory") var reduceMemory = false
    @AppStorage("Model") private var model = ""
    private var progressSubscriber: Cancellable?

    var currentModel: String {
        set {
            NSLog("*** Model set")
            model = newValue
            Task {
                NSLog("*** Loading model")
                await loadModel(model: newValue)
            }
        }
        get {
            return model
        }
    }

    func getSelectedImage() -> SDImage? {
        if (selectedImageIndex == -1) {
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
        }
        else {
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
        let dir = URL(fileURLWithPath: workingDir, isDirectory: true).appending(component: model, directoryHint: .isDirectory)
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
        if case .running = mainViewStatus { return }
        guard let pipeline = pipeline else {
            mainViewStatus = .error("No pipeline available!")
            return
        }
        mainViewStatus = .running(nil)
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
                var s = SDImage()
                s.prompt = self.prompt
                s.negativePrompt = self.negativePrompt
                s.model = self.currentModel
                s.scheduler = self.scheduler
                s.steps = self.steps
                s.guidanceScale = self.guidanceScale

                // Generate
                let batchSize = self.batchSize
                var seedUsed = self.seed == 0 ? UInt32.random(in: 0 ..< UInt32.max) : self.seed
                for _ in 0 ..< self.numberOfBatches {
                    let (imgs, seed) = try pipeline.generate(
                        prompt: s.prompt,
                        negativePrompt: s.negativePrompt,
                        batchSize: batchSize,
                        numInferenceSteps: s.steps,
                        seed: seedUsed,
                        guidanceScale: Float(s.guidanceScale),
                        scheduler: s.scheduler)
                    if pipeline.hasGenerationBeenStopped {
                        break
                    }
                    var simgs = [SDImage]()
                    for (ndx, img) in imgs.enumerated() {
                        s.image = img
                        s.width = img.width
                        s.height = img.height
                        s.seed = seed
                        s.imageIndex = ndx
                        s.generatedDate = Date.now
                        simgs.append(s)
                    }
                    DispatchQueue.main.async {
                        if self.upscaleGeneratedImages {
                            self.upscaleThenAddImages(simgs: simgs)
                        }
                        else {
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
        sdi.isUpscaled = true
        sdi.generatedDate = Date.now
        images.append(sdi)
        selectedImageIndex = newImageIndex
    }

    func upscaleCurrentImage() {
        guard var sdi = getSelectedImage(), let img = sdi.image else { return }
        if sdi.isUpscaled { return }

        guard let upscaledImage = upscaler.upscale(cgImage: img) else { return }
        let newImageIndex = images.count
        sdi.image = upscaledImage
        sdi.width = upscaledImage.width
        sdi.height = upscaledImage.height
        sdi.isUpscaled = true
        sdi.generatedDate = Date.now
        images.append(sdi)
        selectedImageIndex = newImageIndex
    }

    func selectImage(index: Int) {
        selectedImageIndex = index
    }

    func removeImage(index: Int) {
        images.remove(at: index)
        if index <= selectedImageIndex {
            if selectedImageIndex != 0 || images.count == 0 {
                selectedImageIndex -= 1
            }
        }
    }

    func removeCurrentImage() {
        removeImage(index: selectedImageIndex)
    }

    func copyToPrompt() {
        guard let sdi = getSelectedImage() else { return }
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
        guard let sdi = getSelectedImage() else { return }
        prompt = sdi.prompt
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = getSelectedImage() else { return }
        negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = getSelectedImage() else { return }
        scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = getSelectedImage() else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = getSelectedImage() else { return }
        steps = sdi.steps
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = getSelectedImage() else { return }
        guidanceScale = sdi.guidanceScale
    }

    @MainActor
    private func addImages(simgs: [SDImage]) {
        let newImageIndex = self.images.count
        self.images.append(contentsOf: simgs)
        self.selectedImageIndex = newImageIndex
    }

    @MainActor
    private func upscaleThenAddImages(simgs: [SDImage]) {
        var upscaledSDImgs = [SDImage]()
        for simg in simgs {
            guard let img = simg.image else { continue }
            guard let upscaledImage = upscaler.upscale(cgImage: img) else { continue }
            var sdi = simg
            sdi.image = upscaledImage
            sdi.width = upscaledImage.width
            sdi.height = upscaledImage.height
            sdi.isUpscaled = true
            upscaledSDImgs.append(sdi)
        }
        self.addImages(simgs: upscaledSDImgs)
    }
}
