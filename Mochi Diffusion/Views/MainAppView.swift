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

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                Group {
                    PromptView()

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
                            store.loadModels()
                        }) {
                            Image(systemName: "arrow.clockwise")
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
                
//                Group {
//                    HStack {
//                        VStack(alignment: .leading) {
//                            Text("Width:")
//                            Picker("", selection: $store.width) {
//                                Text("512").tag(512)
//                                Text("768").tag(768)
//                            }
//                            .labelsHidden()
//                        }
//                        VStack(alignment: .leading) {
//                            Text("Height:")
//                            Picker("", selection: $store.height) {
//                                Text("512").tag(512)
//                                Text("768").tag(768)
//                            }
//                            .labelsHidden()
//                        }
//                    }
//                    Spacer().frame(height: 16)
//                }

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
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if store.images.count > 0 {
                    Divider()

                    ScrollView(.horizontal) {
                        HStack(alignment: .center, spacing: 12) {
                            ForEach(Array(store.images.enumerated()), id: \.offset) { i, img in
                                Image(img.image!, scale: 5, label: Text(String(img.seed)))
                                    .onTapGesture {
                                        store.selectImage(index: i)
                                    }
                            }
                        }
                        .padding([.leading, .trailing], 12)
                    }
                    .frame(height: 125)
                }
            }
            .toolbar {
                MainToolbar()
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
        return AnyView(
            ProgressView(label: { Text("Loading Model...") })
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding())
    }
}

struct MainAppView_Previews: PreviewProvider {
    static var previews: some View {
        MainAppView().previewLayout(.sizeThatFits)
    }
}
