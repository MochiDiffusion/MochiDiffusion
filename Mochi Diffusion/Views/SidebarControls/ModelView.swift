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
    @EnvironmentObject private var controller: ImageController

    var body: some View {
        Text("Model")
            .sidebarLabelFormat()
        HStack {
            Picker("", selection: $controller.currentModel) {
                ForEach(controller.models) { model in
                    Text(verbatim: model.name).tag(Optional(model))
                }
            }
            .labelsHidden()
            Button(action: openDirectoryInFinder) {
                Text("…")
            }.help("Open models directory in Finder")
        }
    }

    private func openDirectoryInFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: controller.modelDir))
    }
}

#Preview {
    ModelView()
        .environmentObject(ImageController.shared)
}
