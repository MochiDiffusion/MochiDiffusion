//
//  AppState.swift
//  Diffusion
//
//  Created by Fahim Farook on 12/17/2022.
//

import Foundation
import SwiftUI
import CoreML
import Combine
import StableDiffusion

final class Store: ObservableObject {
    @Published var pipeline: Pipeline? = nil
    @Published var modelDir = URL(string: "temp")!
    @Published var models = [String]()
    @Published var images = [SDImage]()
    @Published var selectedImage: SDImage? = nil
    @Published var mainViewStatus: MainViewStatus = .loading
    @Published var width = 512
    @Published var height = 512
    @Published var imageCount = 1
    @Published var seed = 0
    @AppStorage("prompt") var prompt = ""
    @AppStorage("negativePrompt") var negativePrompt = ""
    @AppStorage("steps") var steps = 28
    @AppStorage("scale") var guidanceScale = 11.0
    @AppStorage("model") var model = ""
    @AppStorage("scheduler") var scheduler = StableDiffusionScheduler.dpmSolverMultistepScheduler

    var currentModel: String {
        set {
            NSLog("*** Model set")
            Task {
                NSLog("*** Loading model")
                model = newValue
                await load(model: newValue)
            }
        }
        get {
            return model
        }
    }

    init() {
        NSLog("*** AppState initialized")
        // Does the model path exist?
        guard var dir = docDir else {
            mainViewStatus = .error("Could not get user document directory")
            return
        }
        dir.append(path: "MochiDiffusion/models", directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            NSLog("Models directory does not exist at: \(dir.path). Creating ...")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        modelDir = dir
        // Find models in model dir
        do {
            let subs = try dir.subDirectories()
            subs.forEach {sub in
                models.append(sub.lastPathComponent)
            }
        } catch {
            mainViewStatus = .error("Could not get sub-folders under model directory: \(dir.path)")
            return
        }
        NSLog("*** Setting model")
        if let firstModel = models.first {
            self.currentModel = model.isEmpty ? firstModel : model
        } else {
            mainViewStatus = .error("No models found under model directory: \(dir.path)")
            return
        }
    }

    func load(model: String) async {
        NSLog("*** Loading model: \(model)")
        let dir = modelDir.appending(component: model, directoryHint: .isDirectory)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            let msg = "Model directory: \(model) does not exist at: \(dir.path). Cannot proceed."
            NSLog(msg)
            mainViewStatus = .error(msg)
            return
        }
        let beginDate = Date()
        let configuration = MLModelConfiguration()
        // .all works for v1.4, but not for v1.5
        configuration.computeUnits = .cpuAndGPU
        do {
            let pipeline = try StableDiffusionPipeline(resourcesAt: dir, configuration: configuration, disableSafety: true)
            NSLog("Pipeline loaded in \(Date().timeIntervalSince(beginDate))")
            DispatchQueue.main.async {
                self.pipeline = Pipeline(pipeline)
                self.mainViewStatus = .ready("Ready")
            }
        } catch {
            NSLog("Error loading model: \(error)")
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
