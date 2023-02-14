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
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        VStack(spacing: 16) {
            TabView {
                generalView
                    .tabItem {
                        Label {
                            Text(
                                "General",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "gearshape")
                        }
                    }
                imageView
                    .tabItem {
                        Label {
                            Text(
                                "Image",
                                comment: "Settings tab header label"
                            )
                        } icon: {
                            Image(systemName: "photo")
                        }
                    }
            }

            HStack {
                Spacer()

                Button {
                    Task {
                        await ImageController.shared.loadModels()
                        NSApplication.shared.keyWindow?.close()
                    }
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

    @ViewBuilder
    private var generalView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Reduce Memory Usage")

                        Spacer()

                        Toggle("", isOn: $controller.reduceMemory)
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
                    HStack {
                        Text("Filter Inappropriate Images")

                        Spacer()

                        Toggle("", isOn: $controller.safetyChecker)
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

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Model Folder")

                    HStack {
                        TextField("", text: $controller.modelDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: controller.modelDir).absoluteURL])
                        } label: {
                            Image(systemName: "magnifyingglass.circle.fill")
                                .foregroundColor(Color.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help("Open in Finder")
                    }
                }
                .padding(4)
            }
        }
    }

    @ViewBuilder
    private var imageView: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                HStack {
                    Text("Scheduler")

                    Spacer()

                    Picker("", selection: $controller.scheduler) {
                        ForEach(Scheduler.allCases, id: \.self) { scheduler in
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

                        Picker("", selection: $controller.mlComputeUnit) {
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
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ImageController.shared)
    }
}
