//
//  Pipeline.swift
//  Diffusion
//
//  Created by Pedro Cuenca on December 2022.
//  See LICENSE at https://github.com/huggingface/swift-coreml-diffusers/LICENSE
//

import Combine
import CoreML
import Foundation
import StableDiffusion

typealias StableDiffusionProgress = StableDiffusionPipeline.Progress

class Pipeline {
    let pipeline: StableDiffusionPipeline
    var progress: StableDiffusionProgress? {
        didSet {
            progressPublisher.value = progress
        }
    }
    var hasGenerationBeenStopped: Bool {
        generationStopped
    }

    // swiftlint:disable:next line_length
    private(set) lazy var progressPublisher: CurrentValueSubject<StableDiffusionProgress?, Never> = CurrentValueSubject(progress)
    private var generationStopped = false

    init(_ pipeline: StableDiffusionPipeline) {
        self.pipeline = pipeline
    }

    func generate(
        prompt: String,
        negativePrompt: String,
        numInferenceSteps stepCount: Int,
        seed: UInt32,
        guidanceScale: Float,
        scheduler: StableDiffusionScheduler
    ) throws -> ([CGImage], UInt32) {
        let beginDate = Date()
        print("Generating...")
        generationStopped = false
        let images = try pipeline.generateImages(
            prompt: prompt,
            negativePrompt: negativePrompt,
            imageCount: 1,
            stepCount: stepCount,
            seed: seed,
            guidanceScale: guidanceScale,
            disableSafety: true,
            scheduler: scheduler
        ) { progress in
            handleProgress(progress)
        }
        print("Generation took \(Date().timeIntervalSince(beginDate))")

        let imgs = images.compactMap { $0 }
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
