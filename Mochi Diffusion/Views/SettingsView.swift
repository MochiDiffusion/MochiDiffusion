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
                Text("CPU & Neural Engine option works best with M1 and later or for reducing memory.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("CPU & GPU option works best with M1 Pro, Max, Ultra and later.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("Appropriate model will need to be provided based on the option selected.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                
                Spacer().frame(height: 12)
                
                
                Toggle("Reduce Memory Pressure:", isOn: $store.reduceMemory)
                    .toggleStyle(.switch)
                Text("Recommended for Macs with 8GB of memory.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                
                Spacer().frame(height: 12)
                
                TextField(text: $store.workingDir) {
                    Text("Working Directory:")
                }
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
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
        .frame(width: 700, height: 250, alignment: .top)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
