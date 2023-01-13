//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import SwiftUI
import CoreML

struct ModelView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Text("Model:",
             comment: "Label for Model picker")
        HStack {
            Picker("", selection: $store.currentModel) {
                ForEach(store.models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()

            Button(action: store.loadModels) {
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
