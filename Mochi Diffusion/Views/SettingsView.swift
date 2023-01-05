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
        VStack(alignment: .leading) {
            Form {
                Group {
                    Picker("Scheduler:", selection: $store.scheduler) {
                        ForEach(StableDiffusionScheduler.allCases, id: \.self) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .fixedSize()
                }
                
                Spacer().frame(height: 12)
                
#if arch(arm64)
                Group {
                    Picker("ML Compute Unit:", selection: $store.mlComputeUnit) {
                        Text("CPU & Neural Engine",
                             tableName: "Settings",
                             comment: "CPU & Neural Engine option for compute unit")
                            .tag(MLComputeUnits.cpuAndNeuralEngine)
                        Text("CPU & GPU",
                             tableName: "Settings",
                             comment: "CPU & GPU option for compute unit")
                            .tag(MLComputeUnits.cpuAndGPU)
                        Text("All", tableName: "Settings", comment: "Option to use all CPU, GPU, & Neural Engine for compute unit")
                            .tag(MLComputeUnits.all)
                    }
                    .fixedSize()
                    
                    Text("CPU & Neural Engine provides a good balance between speed and low memory usage.",
                         tableName: "Settings",
                         comment: "Help text for compute unit picker")
                        .helpTextFormat()
                    
                    Text("CPU & GPU may be faster on M1 Max, Ultra and later but will use more memory.",
                         tableName: "Settings",
                         comment: "Help text for compute unit picker")
                        .helpTextFormat()
                    
                    Text("Based on the option selected the correct model version will need to be used.",
                         tableName: "Settings",
                         comment: "Help text for compute unit picker")
                        .helpTextFormat()
                }
                
                Spacer().frame(height: 12)
#endif
                
                Group {
                    Toggle("Reduce Memory Usage:", isOn: $store.reduceMemory)
                        .toggleStyle(.switch)
                    Text("Reduce memory usage further at the cost of speed.",
                         tableName: "Settings",
                         comment: "Help text for Reduce Memory Usage option")
                        .helpTextFormat()
                }
                
                Spacer().frame(height: 12)
                
                HStack {
                    TextField(text: $store.workingDir) {
                        Text("Working Directory:",
                             tableName: "Settings",
                             comment: "Label for changing the working directory")
                    }
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.workingDir).absoluteURL])
                    }) {
                        Image(systemName: "magnifyingglass.circle.fill")
                            .foregroundColor(Color.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Open in Finder")
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                
                Button("Apply") {
                    store.loadModels()
                }
            }
        }
        .padding()
        .frame(width: 690, height: 280, alignment: .top)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
