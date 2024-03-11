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
    @Environment(ImageController.self) private var controller: ImageController

    var body: some View {
        @Bindable var controller = controller

        Text("Model")
            .sidebarLabelFormat()
        HStack {
            Picker("", selection: $controller.currentModel) {
                ForEach(controller.models) { model in
                    Text(verbatim: model.name).tag(Optional(model))
                }
            }
            .labelsHidden()

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: controller.modelDir))
            } label: {
                Text(verbatim: "...")
            }
            .help("Show models in Finder")
        }
    }
}

#Preview {
    ModelView()
        .environment(ImageController.shared)
}
