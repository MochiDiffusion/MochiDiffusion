//
//  MainAppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI
import Sliders
import Combine
import StableDiffusion

struct MainAppView: View {
    @EnvironmentObject var store: Store
    @State private var progressSubscriber: Cancellable?
    @State private var progressSubs: Cancellable?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                Group {
                    PromptView(prompt: $store.prompt, negativePrompt: $store.negativePrompt, submit: self.submit)

                    Divider().frame(height: 16)
                }

                Group {
                    Text("Model:")
                    HStack {
                        Picker("", selection: $store.currentModel) {
                            ForEach(store.models, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        .labelsHidden()
                        
                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([$store.modelDir.wrappedValue.absoluteURL])
                        }) {
                            Image(systemName: "folder")
                        }
                    }
                    Spacer().frame(height: 16)
                }
                
                Group {
                    Text("Scheduler:")
                    Picker("", selection: $store.scheduler) {
                        ForEach(StableDiffusionScheduler.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .labelsHidden()
                    
                    Spacer().frame(height: 16)
                }

                Group {
                    Text("Steps: \(store.steps)")
                    ValueSlider(value: $store.steps, in: 1 ... 200, step: 1)
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
                    Text("Guidance Scale: \(store.guidanceScale, specifier: "%.1f")")
                    ValueSlider(value: $store.guidanceScale, in: 1 ... 20, step: 0.5)
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
                    Text("Number of Images: \(store.imageCount)")
                    ValueSlider(value: $store.imageCount, in: 1 ... 8, step: 1)
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
                    TextField("random", value: $store.seed, formatter: Formatter.seedFormatter)
                        .textFieldStyle(.roundedBorder)
                    Spacer()
                }
            }
            .padding()
        } detail: {
            VStack(alignment: .center) {
                if case .loading = store.mainViewStatus {
//                    ErrorBanner(errorMessage: "Loading...")
                } else if case let .error(msg) = store.mainViewStatus {
                    ErrorBanner(errorMessage: msg)
                } else if case let .running(progress) = store.mainViewStatus {
                    getProgressView(progress: progress)
                }

                if case .running = store.mainViewStatus {
                    // TODO figure out how this works in Swift...
                }
                else {
                    PreviewView()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }

                if store.images.count > 0 {
                    Divider()

                    ScrollView {
                        HStack(spacing: 12) {
                            ForEach(Array(store.images.enumerated()), id: \.offset) { i, img in
                                Image(img.image!, scale: 5, label: Text(String(img.seed)))
                                    .onTapGesture {
                                        store.selectImage(index: i)
                                    }
                            }
                        }
                    }
                    .frame(height: 112)
                }
            }
            .toolbar {
                MainToolbar()
            }
        }
        .onAppear {
            // Pipeline progress subscriber
            progressSubscriber = store.pipeline?.progressPublisher.sink { progress in
                guard let progress = progress else { return }
                store.mainViewStatus = .running(progress)
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
        return AnyView(ProgressView(label: { Text("Loading Model...") }).progressViewStyle(.linear).padding())
    }

    private func submit() {
        if case .running = store.mainViewStatus { return }
        guard let pipeline = store.pipeline else {
            store.mainViewStatus = .error("No pipeline available!")
            return
        }
        store.mainViewStatus = .running(nil)
        // Pipeline progress subscriber
        progressSubs = pipeline.progressPublisher.sink { progress in
            guard let progress = progress else { return }
            DispatchQueue.main.async {
                store.mainViewStatus = .running(progress)
            }
        }
        DispatchQueue.global(qos: .default).async {
            do {
                // Save settings used to generate
                var s = SDImage()
                s.prompt = store.prompt
                s.negativePrompt = store.negativePrompt
                s.width = store.width
                s.height = store.height
                s.model = store.currentModel
                s.scheduler = store.scheduler
                s.steps = store.steps
                s.guidanceScale = store.guidanceScale
                
                // Generate
                let (imgs, seed) = try pipeline.generate(
                    prompt: store.prompt,
                    negativePrompt: store.negativePrompt,
                    imageCount: Int(store.imageCount),
                    numInferenceSteps: Int(store.steps),
                    seed: UInt32(store.seed),
                    guidanceScale: Float(store.guidanceScale),
                    scheduler: store.scheduler)
                progressSubs?.cancel()
                
                var simgs = [SDImage]()
                for (ndx, img) in imgs.enumerated() {
                    s.image = img
                    s.seed = seed
                    s.imageIndex = ndx
                    simgs.append(s)
                }
                DispatchQueue.main.async {
                    store.selectedImage = simgs.first
                    store.images.append(contentsOf: simgs)
                    store.mainViewStatus = .ready("Image generation complete")
                }
            } catch {
                let msg = "Error generating images: \(error)"
                NSLog(msg)
                DispatchQueue.main.async {
                    store.mainViewStatus = .error(msg)
                }
            }
        }
    }
}

struct MainAppView_Previews: PreviewProvider {
    static var previews: some View {
        MainAppView().previewLayout(.sizeThatFits)
    }
}
