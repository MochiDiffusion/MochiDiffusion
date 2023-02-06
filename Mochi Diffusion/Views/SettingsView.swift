//
//  SettingsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import CoreML
import StableDiffusion
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var genStore: GeneratorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                HStack {
                    Text("Scheduler")

                    Spacer()

                    Picker("", selection: $genStore.scheduler) {
                        ForEach(StableDiffusionScheduler.allCases, id: \.self) { scheduler in
                            Text(scheduler.rawValue).tag(scheduler)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(4)

                #if arch(arm64)
                Divider()

                VStack(alignment: .leading) {
                    HStack {
                        Text("ML Compute Unit")

                        Spacer()

                        Picker("", selection: $genStore.mlComputeUnit) {
                            Text("CPU & Neural Engine")
                                .tag(MLComputeUnits.cpuAndNeuralEngine)
                            Text("CPU & GPU")
                                .tag(MLComputeUnits.cpuAndGPU)
                            Text(
                                "All",
                                comment: "Option to use all CPU, GPU, & Neural Engine for compute unit"
                            )
                            .tag(MLComputeUnits.all)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("CPU & Neural Engine provides a good balance between speed and low memory usage.")
                        .helpTextFormat()

                    Text("CPU & GPU may be faster on M1 Max, Ultra and later but will use more memory.")
                        .helpTextFormat()

                    Text(
                        "Based on the option selected the correct model version will need to be used.",
                        comment: "Help text for ML Compute Unit option under Settings"
                    )
                    .helpTextFormat()
                }
                .padding(4)
                #endif

                Divider()

                VStack(alignment: .leading) {
                    HStack {
                        Text("Reduce Memory Usage")

                        Spacer()

                        Toggle("", isOn: $genStore.reduceMemory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Text(
                        "Reduce memory usage further at the cost of speed.",
                        comment: "Help text for Reduce Memory Usage option"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Model Folder")

                    HStack {
                        TextField("", text: $genStore.modelDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: genStore.modelDir).absoluteURL])
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(Color.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Open in Finder")
                    }
                }
                .padding(4)

                Divider()

                VStack(alignment: .leading) {
                    HStack {
                        Text("Filter Inappropriate Images")

                        Spacer()

                        Toggle("", isOn: $genStore.safetyChecker)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Text(
                        "Uses the model's safety checker module. This does not guarantee that all inappropriate images will be filtered.",
                        comment: "Help text for Filter Inappropriate Images option"
                    )
                    .helpTextFormat()
                }
                .padding(4)
            }

            HStack {
                Spacer()

                Button {
                    genStore.loadModels()
                    NSApplication.shared.keyWindow?.close()
                } label: {
                    Text(
                        "Apply",
                        comment: "Button to apply the selected settings"
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, alignment: .top)
        .fixedSize()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()

    static var previews: some View {
        SettingsView()
            .environmentObject(genStore)
    }
}
