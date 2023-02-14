//
//  ImageController+ImageStore.swift
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

class ImageStore {

    @Published
    private(set) var images: [SDImage] = []

    func saveAll() {
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

    func importImages() {
        fatalError()
    }

    func filter(_ text: String) -> [SDImage] {
        images.filter {
            $0.prompt.range(of: text, options: .caseInsensitive) != nil ||
            $0.seed == UInt32(text)
        }
    }

    fileprivate func add(_ sdi: SDImage) -> SDImage.ID {
        var sdiToAdd = sdi
        sdiToAdd.id = UUID()
        images.append(sdiToAdd)
        return sdiToAdd.id
    }

    fileprivate func add(_ sdis: [SDImage]) {
        images.append(contentsOf: sdis)
    }

    fileprivate func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    fileprivate func remove(_ id: SDImage.ID) {
        if let index = index(for: id) {
            images.remove(at: index)
        }
    }

    fileprivate func update(_ sdi: SDImage) {
        if let index = index(for: sdi.id) {
            images[index] = sdi
        }
    }

    fileprivate func index(for id: SDImage.ID) -> Int? {
        images.firstIndex { $0.id == id }
    }

    fileprivate func image(with id: UUID) -> SDImage? {
        images.first { $0.id == id }
    }
}

typealias StableDiffusionProgress = StableDiffusionPipeline.Progress

@MainActor
final class ImageController: ImageStore, ObservableObject {

    static let shared = ImageController()

    private lazy var logger = Logger()

    enum State {
        case idle
        case ready
        case error(String)
        case loading
        case running(StableDiffusionProgress?)
    }

    @Published
    private(set) var state = State.idle

    @Published
    var models = [SDModel]()

    @Published
    var selectedImageIndex = -1

    @Published
    var numberOfImages = 1

    @Published
    var seed: UInt32 = 0

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
                    state = .ready
                } catch ImageGenerator.GeneratorError.modelNotFound {
                    modelName = ""
                    currentModel = nil
                    state = .error("Couldn't load \(model.name) because it doesn't exist.")
                } catch {
                    modelName = ""
                    currentModel = nil
                    state = .error("There was a problem loading the model: \(model.name)")
                }
            }
        }
    }

    var selectedImage: SDImage? {
        if selectedImageIndex == -1 {
            return nil
        }
        return images[selectedImageIndex]
    }

    override init() {
        super.init()
        Task {
            await logger.info("Generator init")
            await loadModels()
        }
    }

    func loadModels() async {
        logger.info("Started loading model directory at: \"\(self.modelDir)\"")
        models = []
        let fm = FileManager.default
        var finalModelDir: URL
        // check if saved model directory exists
        if modelDir.isEmpty {
            // use default model directory
            guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
                modelName = ""
                state = .error("Couldn't access model directory.")
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
            subDirs
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }
                .forEach {
                    let model = SDModel(url: $0, name: $0.lastPathComponent)
                    self.models.append(model)
                }
        } catch {
            logger.notice("Could not get model subdirectories under: \"\(finalModelDir.path(percentEncoded: false))\"")
            state = .error("Could not get model subdirectories.")
            return
        }
        guard let firstModel = models.first else {
            self.modelName = ""
            state = .error("No models found under: \(finalModelDir.path(percentEncoded: false))")
            return
        }
        logger.info("Found \(self.models.count) model(s)")
        let model = models.first { $0.name == modelName }
        guard let model = model else {
            self.currentModel = firstModel
            return
        }
        self.currentModel = modelName.isEmpty ? firstModel : model
    }

    func generate() async {
        if case .ready = state {
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
            numberOfImages: numberOfImages,
            model: modelName,
            mlComputeUnit: mlComputeUnit,
            scheduler: scheduler,
            upscaleGeneratedImages: upscaleGeneratedImages
        )

        do {
            state = .loading
            let sdImages = try await ImageGenerator.shared.generate(genConfig)
            add(sdImages)
            state = .ready
        } catch ImageGenerator.GeneratorError.pipelineNotAvailable {
            logger.error("Pipeline is not loaded.")
            state = .error("Pipeline is not loaded.")
        } catch {
            logger.error("There was a problem generating images: \(error)")
            state = .error("There was a problem generating images: \(error)")
        }
    }

    func upscale(sdi: SDImage) async {
        fatalError()
    }

    func upscaleCurrentImage() async {
        fatalError()
    }

    func removeImage(_ index: Int) async {
        fatalError()
    }

    func removeCurrentImage() async {
        fatalError()
    }

    func selectPrevious() async {
        fatalError()
    }

    func selectNext() async {
        fatalError()
    }

    func copyToPrompt() {
        guard let sdi = selectedImage else { return }
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
        guard let sdi = selectedImage else { return }
        prompt = sdi.prompt
    }

    func copyNegativePromptToPrompt() {
        guard let sdi = selectedImage else { return }
        negativePrompt = sdi.negativePrompt
    }

    func copySchedulerToPrompt() {
        guard let sdi = selectedImage else { return }
        scheduler = sdi.scheduler
    }

    func copySeedToPrompt() {
        guard let sdi = selectedImage else { return }
        seed = sdi.seed
    }

    func copyStepsToPrompt() {
        guard let sdi = selectedImage else { return }
        steps = Double(sdi.steps)
    }

    func copyGuidanceScaleToPrompt() {
        guard let sdi = selectedImage else { return }
        guidanceScale = sdi.guidanceScale
    }
}
