//
//  MainAppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI
import Sliders
import Combine

enum MainViewState {
    case loading
    case idle
    case ready(String)
    case error(String)
    case running(StableDiffusionProgress?)
}

struct MainAppView: View {
    @StateObject var context = AppState.shared
    
    @State private var prompt = ""
    @State private var negativePrompt = ""
    @AppStorage("steps") private var steps = 28
    @AppStorage("scale") private var guidanceScale = 11.0
    @State private var width = 512
    @State private var height = 512
    @State private var imageCount = 1
    @State private var seed = 0
    @State private var image: CGImage? = nil
    @State private var images = [CGImage]()
    @State private var state: MainViewState = .loading
    
    @State private var stateSubscriber: Cancellable?
    @State private var progressSubscriber: Cancellable?
    @State private var progressSubs: Cancellable?
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading) {
                Group {
                    TextField("Prompt", text: $prompt, axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                        .onSubmit {
                            submit()
                        }
                        .padding(.bottom, 4)
                    
                    Spacer().frame(height: 8)
                }
                
                Group {
                    TextField("Negative Prompt", text: $negativePrompt, axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                        .onSubmit {
                            submit()
                        }
                        .padding(.bottom, 4)
                    
                    Spacer().frame(height: 8)
                }
                
                Group {
                    HStack {
                        Spacer()
                        Button("Generate") {
                            submit()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                    Spacer().frame(height: 8)
                }
                
                Divider().padding(.bottom, 4)
                
                Group {
                    HStack {
                        Picker("Model: ", selection: $context.currentModel) {
                            ForEach(context.models, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([$context.modelDir.wrappedValue.absoluteURL])
                        }) {
                            Image(systemName: "folder")
                        }
                    }
                    Spacer().frame(height: 16)
                }
                
                Group {
                    Text("Steps: \(steps)")
                    ValueSlider(value: $steps, in: 1 ... 200, step: 1)
                        .valueSliderStyle(
                            HorizontalValueSliderStyle(
                                track:
                                    HorizontalTrack(view: Color.accentColor)
                                    .frame(height: 12)
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(6),
                                thumbSize: CGSize(width: 12, height: 12),
                                options: .interactiveTrack
                            )
                        )
                        .frame(height: 12)
                    Spacer().frame(height: 16)
                }
                
                Group {
                    Text("Guidance Scale: \(guidanceScale, specifier: "%.1f")")
                    ValueSlider(value: $guidanceScale, in: 1 ... 20, step: 0.5)
                        .valueSliderStyle(
                            HorizontalValueSliderStyle(
                                track:
                                    HorizontalTrack(view: Color.accentColor)
                                    .frame(height: 12)
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(6),
                                thumbSize: CGSize(width: 12, height: 12),
                                options: .interactiveTrack
                            )
                        )
                        .frame(height: 12)
                    Spacer().frame(height: 16)
                }
                
                Group {
                    Text("Number of Images: \(imageCount)")
                    ValueSlider(value: $imageCount, in: 1 ... 8, step: 1)
                        .valueSliderStyle(
                            HorizontalValueSliderStyle(
                                track:
                                    HorizontalTrack(view: Color.accentColor)
                                    .frame(height: 12)
                                    .background(Color.black.opacity(0.2))
                                    .cornerRadius(6),
                                thumbSize: CGSize(width: 12, height: 12),
                                options: .interactiveTrack
                            )
                        )
                        .frame(height: 12)
                    Spacer().frame(height: 16)
                }
                
                Group {
                    Text("Seed (0 for random):")
                    TextField("random", value: $seed, formatter: Formatter.seedFormatter)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                }
            }
            .padding()
            
            VStack(alignment: .center) {
                if case .loading = state {
//                    ErrorBanner(errorMessage: "Loading...")
                } else if case let .error(msg) = state {
                    ErrorBanner(errorMessage: msg)
                } else if case let .running(progress) = state {
                    getProgressView(progress: progress)
                }
                
                if case .running = state {
                    // TODO figure out how this works in Swift...
                }
                else {
                    PreviewView(image: $image, prompt: $prompt)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
                
                if images.count > 0 {
                    Divider()
                    
                    ScrollView {
                        HStack(spacing: 12) {
                            ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                                Image(img, scale: 5, label: Text(""))
                                    .onTapGesture {
                                        selectImage(index: i)
                                    }
                            }
                        }
                    }
                    .frame(height: 116)
                }
            }
        }
        .onAppear {
            // AppState state subscriber
            stateSubscriber = context.statePublisher.sink { state in
                DispatchQueue.main.async {
                    self.state = state
                }
            }
            // Pipeline progress subscriber
            progressSubscriber = context.pipeline?.progressPublisher.sink { progress in
                guard let progress = progress else { return }
                state = .running(progress)
            }
        }
    }
    
    private func getProgressView(progress: StableDiffusionProgress?) -> AnyView {
        if let progress = progress, progress.stepCount > 0 {
            let step = Int(progress.step) + 1
            let fraction = Double(step) / Double(progress.stepCount)
            let label = "Step \(step) of \(progress.stepCount)"
            return AnyView(
                ProgressView(label, value: fraction, total: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding())
        }
        // The first time it takes a little bit before generation starts
        return AnyView(ProgressView(label: { Text("Loading...") }).progressViewStyle(.linear).padding())
    }
    
    private func submit() {
        if case .running = state { return }
        guard let pipeline = context.pipeline else {
            state = .error("No pipeline available!")
            return
        }
        state = .running(nil)
        // Pipeline progress subscriber
        progressSubs = pipeline.progressPublisher.sink { progress in
            guard let progress = progress else { return }
            DispatchQueue.main.async {
                state = .running(progress)
            }
        }
        DispatchQueue.global(qos: .default).async {
            do {
                // Generate
                let imgs = try pipeline.generate(
                    prompt: prompt,
                    negativePrompt: negativePrompt,
                    imageCount: Int(imageCount),
                    numInferenceSteps: Int(steps),
                    seed: UInt32(seed),
                    guidanceScale: Float(guidanceScale))
                progressSubs?.cancel()
                DispatchQueue.main.async {
                    image = imgs.first
                    images.append(contentsOf: imgs)
                    state = .ready("Image generation complete")
                }
            } catch {
                let msg = "Error generating images: \(error)"
                NSLog(msg)
                DispatchQueue.main.async {
                    state = .error(msg)
                }
            }
        }
    }
    
    private func selectImage(index: Int) {
        image = images[index]
    }
}

struct MainAppView_Previews: PreviewProvider {
    static var previews: some View {
        MainAppView().previewLayout(.sizeThatFits)
    }
}
