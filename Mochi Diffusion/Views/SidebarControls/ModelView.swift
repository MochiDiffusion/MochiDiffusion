//
//  ModelView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/26/22.
//

import AppKit
import FilterablePicker
import SwiftUI

struct ModelView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @State private var isShowingInfo = false

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
                isShowingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .help("Model Info")
            .popover(isPresented: $isShowingInfo, arrowEdge: .trailing) {
                ModelInfoView()
            }
        }
    }

}

/// The selected model's family, where it lives and runs, and its publisher's
/// recommended settings, which apply only from the button here.
private struct ModelInfoView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model = controller.currentModel {
                Text(model.name)
                    .font(.headline)
                    .textSelection(.enabled)

                Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 6) {
                    if let familyName = model.familyName {
                        row("Family") { Text(familyName) }
                    }
                    switch model.location {
                    case .directory(let url):
                        row("Runs On") { Text("This Mac") }
                        row("Location") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(url.path(percentEncoded: false))
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Button("Reveal in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    case .server(let name, let file):
                        row("Runs On") { Text("Draw Things at \(name)") }
                        row("File") {
                            Text(file)
                                .textSelection(.enabled)
                        }
                    case nil:
                        EmptyView()
                    }
                }

                if model.recommendedSteps != nil || model.recommendedGuidanceScale != nil {
                    Divider()
                    Text("Recommended Settings")
                        .font(.headline)
                    Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 6) {
                        if let steps = model.recommendedSteps {
                            row("Steps") { Text(steps, format: .number) }
                        }
                        if let guidanceScale = model.recommendedGuidanceScale {
                            row("Guidance Scale") {
                                Text(
                                    guidanceScale,
                                    format: .number.precision(.fractionLength(1))
                                )
                            }
                        }
                    }
                    Button("Use Recommended Settings") {
                        controller.applyRecommendedSettings()
                    }
                }
            } else {
                Text("No model is selected.")
                Button("Show Models in Finder") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: configStore.modelDir))
                }
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }

    private func row(
        _ label: LocalizedStringKey,
        @ViewBuilder value: () -> some View
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
