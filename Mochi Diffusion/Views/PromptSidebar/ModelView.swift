//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI

struct ModelView: View {
    @EnvironmentObject var store: Store
    
    var body: some View {
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
    }
}

struct ModelView_Previews: PreviewProvider {
    static var previews: some View {
        ModelView()
    }
}
