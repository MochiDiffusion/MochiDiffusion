//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import CoreML
import SwiftUI

struct ModelView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Text(
            "Model:",
            comment: "Label for Model picker"
        )
        HStack {
            Picker("", selection: $store.currentModel) {
                ForEach(store.models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()

            Button(action: store.loadModels) {
                Image(systemName: "arrow.clockwise")
                    .frame(minWidth: 18)
            }
        }
    }
}

struct ModelView_Previews: PreviewProvider {
    static var previews: some View {
        ModelView()
    }
}
