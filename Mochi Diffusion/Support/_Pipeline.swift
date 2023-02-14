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

// typealias StableDiffusionProgress = StableDiffusionPipeline.Progress

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

    private(set) lazy var progressPublisher: CurrentValueSubject<StableDiffusionProgress?, Never> = CurrentValueSubject(progress)
    private var generationStopped = false

    init(_ pipeline: StableDiffusionPipeline) {
        self.pipeline = pipeline
    }

    func generate(_ configuration: StableDiffusionPipeline.Configuration) throws -> [CGImage] {
        let beginDate = Date()
        print("Generating...")
        generationStopped = false
        let images = try pipeline.generateImages(configuration: configuration) { progress in
            handleProgress(progress)
        }
        print("Generation took \(Date().timeIntervalSince(beginDate))")

        let imgs = images.compactMap { $0 }
        return imgs
    }

    func stopGeneration() {
        generationStopped = true
    }

    private func handleProgress(_ progress: StableDiffusionPipeline.Progress) -> Bool {
        self.progress = progress
        return !generationStopped
    }
}
