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
    lazy private(set) var progressPublisher: CurrentValueSubject<StableDiffusionProgress?, Never> = CurrentValueSubject(progress)
    
    init(_ pipeline: StableDiffusionPipeline) {
        self.pipeline = pipeline
    }
    
    func generate(
        prompt: String,
        negativePrompt: String = "",
        imageCount: Int = 1,
        numInferenceSteps stepCount: Int = 50,
        seed: UInt32? = nil,
        guidanceScale: Float = 7.5
    ) throws -> [CGImage] {
        let beginDate = Date()
        print("Generating...")
        let theSeed = seed ?? UInt32.random(in: 0..<UInt32.max)
        let images = try pipeline.generateImages(
            prompt: prompt,
            negativePrompt: negativePrompt,
            imageCount: imageCount,
            stepCount: stepCount,
            seed: theSeed,
            guidanceScale: guidanceScale,
            disableSafety: true,
            scheduler: StableDiffusionScheduler.dpmSolverMultistepScheduler
        ) { progress in
            handleProgress(progress)
            return true
        }
        print("Got images: \(images) in \(Date().timeIntervalSince(beginDate))")
        
        let imgs = images.compactMap({$0})
        if imgs.count != imageCount {
            throw "Generation failed: got \(imgs.count) instead of \(imageCount)"
        }
        return imgs
    }
    
    func handleProgress(_ progress: StableDiffusionPipeline.Progress) {
        self.progress = progress
    }
}
