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
let scheduler = StableDiffusionScheduler.pndmScheduler

func generate(pipeline: Pipeline?, prompt: String, negativePrompt: String, steps: Int, seed: UInt32?) async -> CGImage? {
    guard let pipeline = pipeline else { return nil }
    return try? pipeline.generate(prompt: prompt, negativePrompt: negativePrompt, numInferenceSteps: steps, seed: seed, scheduler: scheduler)
}

enum GenerationState {
    case startup
    case running(StableDiffusionProgress?)
    case idle(String)
}

struct ImageWithPlaceholder: View {
    var image: Binding<CGImage?>
    var state: Binding<GenerationState>
    
    var body: some View {
        switch state.wrappedValue {
        case .startup: return AnyView(Image(systemName: "photo").resizable())
        case .running(let progress):
            guard let progress = progress, progress.stepCount > 0 else {
                // The first time it takes a little bit before generation starts
                return AnyView(ProgressView())
            }
            let step = Int(progress.step) + 1
            let fraction = Double(step) / Double(progress.stepCount)
            let label = "Step \(step) of \(progress.stepCount)"
            return AnyView(ProgressView(label, value: fraction, total: 1).padding())
        case .idle(let lastPrompt):
            guard let theImage = image.wrappedValue else {
                return AnyView(Image(systemName: "exclamationmark.triangle").resizable())
            }
            
            let imageView = Image(theImage, scale: 1, label: Text("generated"))
            return AnyView(
                VStack {
                    imageView.resizable()
                    ShareLink(item: imageView, preview: SharePreview(lastPrompt, image: imageView))
                })
        }
    }
}

struct TextToImage: View {
    @EnvironmentObject var context: DiffusionGlobals
    
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @State private var steps = 28.0
    @State private var guidanceScale = 11.0
    @State private var seed: UInt32? = nil
    @State private var image: CGImage? = nil
    @State private var state: GenerationState = .startup
    
    @State private var progressSubscriber: Cancellable?
    
    func submit() {
        if case .running = state { return }
        Task {
            state = .running(nil)
            image = await generate(
                pipeline: context.pipeline,
                prompt: prompt,
                negativePrompt: negativePrompt,
                steps: Int(steps),
                seed: seed)
            state = .idle(prompt)
        }
    }
    
    var body: some View {
        HSplitView() {
            VStack(alignment: .leading) {
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submit()
                    }
                
                TextField("Negative Prompt", text: $negativePrompt, axis: .vertical)
                    .lineLimit(4, reservesSpace: true)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submit()
                    }
                
                HStack {
                    Spacer()
                    Button("Generate") {
                        submit()
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Divider()
                
                Group {
                    Text("Steps: \(steps, specifier: "%.0f")")
                    Slider(
                        value: $steps,
                        in: 1...200,
                        step: 1
                    )
                }
                
                Group {
                    Text("Guidance Scale: \(guidanceScale, specifier: "%.1f")")
                    Slider(
                        value: $guidanceScale,
                        in: 1...20,
                        step: 0.5
                    )
                }
                
                Group {
                    Text("Seed: ")
                    TextField("random", value: $seed, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            submit()
                        }
                }
                
                Spacer()
            }
            .padding()
            
            VStack(alignment: .center) {
                ImageWithPlaceholder(image: $image, state: $state)
                    .scaledToFit()
            }
            .padding()
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
