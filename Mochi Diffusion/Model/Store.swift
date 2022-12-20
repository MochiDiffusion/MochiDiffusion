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
    @Published var selectedImage: SDImage? = nil
    @Published var mainViewStatus: MainViewStatus = .loading
    @Published var width = 512
    @Published var height = 512
    @Published var imageCount = 1
    @Published var seed = 0
    @AppStorage("WorkingDir") var workingDir = ""
    @AppStorage("Prompt") var prompt = ""
    @AppStorage("NegativePrompt") var negativePrompt = ""
    @AppStorage("Steps") var steps = 28
    @AppStorage("Scale") var guidanceScale = 11.0
    @AppStorage("Scheduler") var scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler
    @AppStorage("MLComputeUnit") var mlComputeUnit: MLComputeUnits = .cpuAndGPU
    @AppStorage("Model") private var model = ""

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

    init() {
        NSLog("*** AppState initialized")
        loadModels()
    }

    func loadModels() {
        var dir: URL
        let appDir = "MochiDiffusion/models/"
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
            let pipeline = try StableDiffusionPipeline(resourcesAt: dir, configuration: configuration, disableSafety: true)
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

    func selectImage(index: Int) {
        selectedImage = images[index]
    }

    func copyToPrompt() {
        guard let image = selectedImage else { return }
        prompt = image.prompt
        negativePrompt = image.negativePrompt
        steps = image.steps
        guidanceScale = image.guidanceScale
        width = image.width
        height = image.height
        seed = Int(image.seed)
        scheduler = image.scheduler
    }
}
