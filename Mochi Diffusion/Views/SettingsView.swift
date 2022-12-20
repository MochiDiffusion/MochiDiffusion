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
                Text("Note: The \"All\" option is known to have issues with some models")
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
        .frame(width: 550, height: 150, alignment: .top)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
