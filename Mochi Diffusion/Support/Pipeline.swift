//
//  Pipeline.swift
//  Diffusion
//
//  Created by Pedro Cuenca on December 2022.
//  See LICENSE at https://github.com/huggingface/swift-coreml-diffusers/LICENSE
//

import Foundation
import CoreML
import Combine

import StableDiffusion

typealias StableDiffusionProgress = StableDiffusionPipeline.Progress

class Pipeline {
    let pipeline: StableDiffusionPipeline
    var progress: StableDiffusionProgress? = nil {
        didSet {
            progressPublisher.value = progress
        }
    }
    var hasGenerationBeenStopped: Bool {
        get {
            return generationStopped
        }
    }
    
    lazy private(set) var progressPublisher: CurrentValueSubject<StableDiffusionProgress?, Never> = CurrentValueSubject(progress)
    private var generationStopped = false
    
    init(_ pipeline: StableDiffusionPipeline) {
        self.pipeline = pipeline
    }

    func generate(
        prompt: String,
        negativePrompt: String = "",
        batchSize: Int = 1,
        numInferenceSteps stepCount: Int = 50,
        seed: UInt32 = 0,
        guidanceScale: Float = 7.5,
        scheduler: StableDiffusionScheduler
    ) throws -> ([CGImage], UInt32) {
        let beginDate = Date()
        print("Generating...")
        generationStopped = false
        let images = try pipeline.generateImages(
            prompt: prompt,
            negativePrompt: negativePrompt,
            imageCount: batchSize,
            stepCount: stepCount,
            seed: seed,
            guidanceScale: guidanceScale,
            disableSafety: true,
            scheduler: scheduler
        ) { progress in
            return handleProgress(progress)
        }
        print("Got images: \(images) in \(Date().timeIntervalSince(beginDate))")

        let imgs = images.compactMap({$0})
        return (imgs, seed)
    }

    func stopGeneration() {
         generationStopped = true
    }

    private func handleProgress(_ progress: StableDiffusionPipeline.Progress) -> Bool {
        self.progress = progress
        return !generationStopped
    }
}
