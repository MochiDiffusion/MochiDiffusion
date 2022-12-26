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
    @Published var models = [String]()
    @Published var images = [SDImage]()
    @Published var selectedImageIndex = -1
    @Published var mainViewStatus: MainViewStatus = .loading
    @Published var imageCount = 1
    @Published var seed = 0
    @AppStorage("WorkingDir") var workingDir = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 28
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("ImageWidth") var width = 512
    @AppStorage("ImageHeight") var height = 512
    @AppStorage("Scheduler") var scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
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
            subs.forEach {sub in
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
                let (imgs, seed) = try pipeline.generate(
                    prompt: self.prompt,
                    negativePrompt: self.negativePrompt,
                    imageCount: Int(self.imageCount),
                    numInferenceSteps: Int(self.steps),
                    seed: UInt32(self.seed),
                    guidanceScale: Float(self.guidanceScale),
                    scheduler: self.scheduler)
                self.progressSubscriber?.cancel()
                
                var simgs = [SDImage]()
                for (ndx, img) in imgs.enumerated() {
                    s.image = img
                    s.width = img.width
                    s.height = img.height
                    s.seed = seed
                    s.imageIndex = ndx
                    simgs.append(s)
                }
                DispatchQueue.main.async {
                    self.imagesReady(simgs: simgs)
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
        guard let image = getSelectedImage() else { return }
        prompt = image.prompt
        negativePrompt = image.negativePrompt
        steps = image.steps
        guidanceScale = image.guidanceScale
        width = image.width
        height = image.height
        seed = Int(image.seed)
        scheduler = image.scheduler
    }
    
    @MainActor
    private func imagesReady(simgs: [SDImage]) {
        let newImageIndex = self.images.count
        self.images.append(contentsOf: simgs)
        self.selectedImageIndex = newImageIndex
    }
}
