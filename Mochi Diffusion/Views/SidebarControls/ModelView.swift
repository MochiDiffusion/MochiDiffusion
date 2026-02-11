//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import AppKit
import CoreML
import SwiftUI

struct ModelView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var controller = controller

        Text("Model")
            .sidebarLabelFormat()
        HStack {
            Picker("", selection: $controller.currentModelId) {
                ForEach(controller.models, id: \.id) { model in
                    Text(verbatim: model.name).tag(Optional(model.id))
                }
            }
            .labelsHidden()

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: configStore.modelDir))
            } label: {
                Image(systemName: "folder")
            }
            .help("Show models in Finder")
        }
    }
}

#Preview {
    ModelView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(ConfigStore())
}
