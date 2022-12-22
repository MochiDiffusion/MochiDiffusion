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
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
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
                        Spacer().frame(height: 6)
                    }
                    
                    Group {
                        Text("Scheduler:")
                        Picker("", selection: $store.scheduler) {
                            ForEach(StableDiffusionScheduler.allCases, id: \.self) { s in
                                Text(s.rawValue).tag(s)
                            }
                        }
                        .labelsHidden()
                        
                        Spacer().frame(height: 6)
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
                        Spacer().frame(height: 6)
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
                        Spacer().frame(height: 6)
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
                        Spacer().frame(height: 6)
                    }
                    
//                    Group {
//                        HStack {
//                            VStack(alignment: .leading) {
//                                Text("Width:")
//                                Picker("", selection: $store.width) {
//                                    Text("512").tag(512)
//                                    Text("768").tag(768)
//                                }
//                                .labelsHidden()
//                            }
//                            VStack(alignment: .leading) {
//                                Text("Height:")
//                                Picker("", selection: $store.height) {
//                                    Text("512").tag(512)
//                                    Text("768").tag(768)
//                                }
//                                .labelsHidden()
//                            }
//                        }
//                        Spacer().frame(height: 6)
//                    }
                    
                    Group {
                        Text("Seed (0 for random):")
                        TextField("random", value: $store.seed, formatter: Formatter.seedFormatter)
                            .textFieldStyle(.roundedBorder)
                        Spacer()
                    }
                }
                .padding()
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            GalleryView()
        }
    }
}

struct MainAppView_Previews: PreviewProvider {
    static var previews: some View {
        MainAppView().previewLayout(.sizeThatFits)
    }
}
