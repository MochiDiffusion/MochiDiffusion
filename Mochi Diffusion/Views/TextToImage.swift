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

func generate(
    pipeline: Pipeline?,
    prompt: String,
    negativePrompt: String,
    steps: Int,
    seed: UInt32?
) async -> CGImage? {
    guard let pipeline = pipeline else { return nil }
    return try? pipeline.generate(
        prompt: prompt,
        negativePrompt: negativePrompt,
        numInferenceSteps: steps,
        seed: seed,
        scheduler: scheduler)
}

enum GenerationState {
    case startup
    case running(StableDiffusionProgress?)
    case idle(String)
}

struct ImageWithPlaceholder: View {
    var image: Binding<CGImage?>
    var state: Binding<GenerationState>
    
    func showSavePanel() -> URL? {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.title = "Save Image"
        savePanel.message = "Choose a folder and a name to store the image."
        savePanel.nameFieldLabel = "File name:"
        
        let response = savePanel.runModal()
        return response == .OK ? savePanel.url : nil
    }
    
    func saveImage(cgImage: CGImage, path: URL) {
        let image = NSImage(cgImage: cgImage, size: .zero)
        let imageRepresentation = NSBitmapImageRep(data: image.tiffRepresentation!)
        let pngData = imageRepresentation?.representation(using: .png, properties: [:])
        do {
            try pngData!.write(to: path)
        } catch {
            print(error)
        }
    }
    
    var body: some View {
        switch state.wrappedValue {
        case .startup:
            return AnyView(
                Image(systemName: "paintbrush.pointed")
                    .resizable()
                    .foregroundColor(.white.opacity(0.2))
                    .frame(maxWidth: 100, maxHeight: 100))
        case .running(let progress):
            guard let progress = progress, progress.stepCount > 0 else {
                // The first time it takes a little bit before generation starts
                return AnyView(ProgressView())
            }
            let step = Int(progress.step)
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
                    HStack {
                        ShareLink(item: imageView, preview: SharePreview(lastPrompt, image: imageView))
                        Button("Save Image...") {
                            if let url = showSavePanel() {
                                saveImage(cgImage: theImage, path: url)
                            }
                        }
                    }
                })
        }
    }
}

struct TextToImage: View {
    @EnvironmentObject var context: DiffusionGlobals
    
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @AppStorage("steps") private var steps = 28.0
    @AppStorage("scale") private var guidanceScale = 11.0
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
        NavigationView {
            VStack(alignment: .leading) {
                TextField("Prompt", text: $prompt, axis: .vertical)
                    .lineLimit(6, reservesSpace: true)
                    .onSubmit {
                        submit()
                    }
                
                TextField("Negative Prompt", text: $negativePrompt, axis: .vertical)
                    .lineLimit(6, reservesSpace: true)
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
                    SliderView(
                        value: $steps,
                        sliderRange: 1...200
                    )
                    .frame(height: 18)
                }
                
                Group {
                    Text("Guidance Scale: \(guidanceScale, specifier: "%.1f")")
                    SliderView(
                        value: $guidanceScale,
                        sliderRange: 1...20
                    )
                    .frame(height: 18)
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
        .onAppear {
            progressSubscriber = context.pipeline!.progressPublisher.sink { progress in
                guard let progress = progress else { return }
                state = .running(progress)
            }
        }
    }
}
