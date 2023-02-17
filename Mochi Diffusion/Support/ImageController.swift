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
                } catch {
                    modelName = ""
                    currentModel = nil
                }
            }
        }
    }

    var selectedImage: SDImage? {
        if selectedImageIndex == -1 {
            return nil
        }
        return ImageStore.shared.images[selectedImageIndex]
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

    func upscale(sdi: SDImage) async {
        // async let
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

    func importImages() {
        fatalError()
    }

    func saveAll() async {
        if ImageStore.shared.images.isEmpty { return }
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
