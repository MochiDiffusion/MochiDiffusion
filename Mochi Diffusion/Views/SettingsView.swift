//
//  SettingsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI
import CoreML
import StableDiffusion

struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupBox {
                HStack {
                    Text("Scheduler")

                    Spacer()

                    Picker("", selection: $store.scheduler) {
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

                        Picker("", selection: $store.mlComputeUnit) {
                            Text("CPU & Neural Engine")
                                .tag(MLComputeUnits.cpuAndNeuralEngine)
                            Text("CPU & GPU")
                                .tag(MLComputeUnits.cpuAndGPU)
                            Text("All",
                                 comment: "Option to use all CPU, GPU, & Neural Engine for compute unit")
                            .tag(MLComputeUnits.all)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Text("CPU & Neural Engine provides a good balance between speed and low memory usage.")
                        .helpTextFormat()

                    Text("CPU & GPU may be faster on M1 Max, Ultra and later but will use more memory.")
                        .helpTextFormat()

                    Text("Based on the option selected the correct model version will need to be used.",
                         comment: "Help text for ML Compute Unit option under Settings")
                    .helpTextFormat()
                }
                .padding(4)
#endif

                Divider()

                VStack(alignment: .leading) {
                    HStack {
                        Text("Reduce Memory Usage")

                        Spacer()

                        Toggle("", isOn: $store.reduceMemory)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    Text("Reduce memory usage further at the cost of speed.",
                         comment: "Help text for Reduce Memory Usage option")
                    .helpTextFormat()
                }
                .padding(4)
            }

            Spacer().frame(height: 12)

            GroupBox {
                VStack(alignment: .leading) {
                    Text("Working Directory",
                         comment: "Label for changing the working directory")

                    HStack {
                        TextField("", text: $store.workingDir)
                            .disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            // swiftlint:disable:next line_length
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.workingDir).absoluteURL])
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

            Spacer()

            HStack {
                Spacer()

                Button {
                    store.loadModels()
                    NSApplication.shared.keyWindow?.close()
                } label: {
                    Text("Apply",
                         comment: "Button to apply the selected settings")
                }
            }
        }
        .padding()
        .frame(width: 500, alignment: .top)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
