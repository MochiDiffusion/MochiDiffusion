//
//  SettingsView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI
import CoreML

struct SettingsView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
        VStack(alignment: .leading) {
            Form {
                Picker("ML Compute Unit:", selection: $store.mlComputeUnit) {
                    Text("CPU & Neural Engine").tag(MLComputeUnits.cpuAndNeuralEngine)
                    Text("CPU & GPU").tag(MLComputeUnits.cpuAndGPU)
                    Text("All").tag(MLComputeUnits.all)
                }
                .fixedSize()
                Text("CPU & Neural Engine provides a good balance between speed and low memory usage.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("CPU & GPU may be faster on M1 Max, Ultra and later but will use more memory.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Based on the option selected the correct model version will need to be used.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                
                Spacer().frame(height: 12)
                
                
                Toggle("Reduce Memory Usage:", isOn: $store.reduceMemory)
                    .toggleStyle(.switch)
                Text("Reduce memory usage further at the cost of speed.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                
                Spacer().frame(height: 12)
                
                HStack {
                    TextField(text: $store.workingDir) {
                        Text("Working Directory:")
                    }
                    .disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder)
                    
                    Button(action: {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.workingDir).absoluteURL])
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(Color.secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
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
        .frame(width: 690, height: 240, alignment: .top)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
