//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import AppKit
import CoreML
import FilterablePicker
import SwiftUI

struct ModelView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        @Bindable var controller = controller

        Text("Model")
            .sidebarLabelFormat()
        HStack {
            FilterablePicker(
                String(localized: "Model"),
                selection: $controller.currentModelId,
                items: controller.modelPickerItems,
                title: \.name
            )

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: configStore.modelDir))
            } label: {
                Image(systemName: "folder")
            }
            .help("Show models in Finder")
        }
    }

}
