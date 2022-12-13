//
//  TextToImage.swift
//  Diffusion
//
//  Created by Pedro Cuenca on December 2022.
//  See LICENSE at https://github.com/huggingface/swift-coreml-diffusers/LICENSE
//

import SwiftUI
import Combine
import StableDiffusion

// TODO: bind to UI controls
let scheduler = StableDiffusionScheduler.dpmpp
let steps = 25
let seed: UInt32? = nil

func generate(pipeline: Pipeline?, prompt: String) async -> CGImage? {
    guard let pipeline = pipeline else { return nil }
    return try? pipeline.generate(prompt: prompt, scheduler: scheduler, numInferenceSteps: steps, seed: seed)
}

enum GenerationState {
    case startup
    case running(StableDiffusionProgress?)
    case idle
}

struct ImageWithPlaceholder: View {
    var image: Binding<CGImage?>
    var state: Binding<GenerationState>
        
    var body: some View {
        switch state.wrappedValue {
        case .startup: return AnyView(Image("placeholder").resizable())
        case .running(let progress):
            guard let progress = progress, progress.stepCount > 0 else {
                // The first time it takes a little bit before generation starts
                return AnyView(ProgressView())
            }
            let step = Int(progress.step) + 1
            let fraction = Double(step) / Double(progress.stepCount)
            let label = "Step \(step) of \(progress.stepCount)"
            return AnyView(ProgressView(label, value: fraction, total: 1).padding())
        default:
            guard let theImage = image.wrappedValue else {
                return AnyView(Image(systemName: "exclamationmark.triangle").resizable())
            }
                              
            let imageView = Image(theImage, scale: 1, label: Text("generated"))
            return AnyView(
                VStack {
                imageView.resizable().clipShape(RoundedRectangle(cornerRadius: 20))
                ShareLink(item: imageView, preview: SharePreview("Generated image", image: imageView))
            })
        }
    }
}

struct TextToImage: View {
    @EnvironmentObject var context: DiffusionGlobals

    @State private var prompt = "Labrador in the style of Vermeer"
    @State private var image: CGImage? = nil
    @State private var state: GenerationState = .startup
    
    @State private var progressSubscriber: Cancellable?

    func submit() {
        if case .running = state { return }
        Task {
            state = .running(nil)
            image = await generate(pipeline: context.pipeline, prompt: prompt)
            state = .idle
        }
    }
    
    var body: some View {
        VStack {
            HStack {
                TextField("Prompt", text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submit()
                    }
                Button("Generate") {
                    submit()
                }
                .padding()
                .buttonStyle(.borderedProminent)
            }
            ImageWithPlaceholder(image: $image, state: $state)
                .scaledToFit()
            Spacer()
        }
        .padding()
        .onAppear {
            progressSubscriber = context.pipeline!.progressPublisher.sink { progress in
                guard let progress = progress else { return }
                state = .running(progress)
            }
        }
    }
}
