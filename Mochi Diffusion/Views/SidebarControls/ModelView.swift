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

            let differsFromRecommendations =
                !controller.settingsDifferingFromRecommendations.isEmpty
            Button {
                isShowingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .overlay(alignment: .topTrailing) {
                        if differsFromRecommendations {
                            RecommendationBadge()
                        }
                    }
            }
            .help(
                differsFromRecommendations
                    ? "Model Info: some settings differ from this model's recommendations"
                    : "Model Info"
            )
            .popover(isPresented: $isShowingInfo, arrowEdge: .trailing) {
                ModelInfoView()
            }
            .disabled(controller.currentModel == nil)
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
                        row("Runs On") { Text(name) }
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
                    Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                        if let steps = model.recommendedSteps {
                            InfoGridRow(
                                type: "Steps",
                                text: String(steps),
                                showCopyToPromptOption: true,
                                callback: { controller.applyRecommendedSetting(.steps) }
                            )
                        }
                        if let guidanceScale = model.recommendedGuidanceScale {
                            InfoGridRow(
                                type: "Guidance Scale",
                                text: guidanceScale.formatted(
                                    .number.precision(.fractionLength(1))),
                                showCopyToPromptOption: true,
                                callback: { controller.applyRecommendedSetting(.guidanceScale) }
                            )
                        }
                    }
                    Button("Use Recommended Settings") {
                        controller.applyRecommendedSettings()
                    }
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

/// A small dot on the info button while the sidebar differs from the model's
/// recommended settings.
private struct RecommendationBadge: View {
    var body: some View {
        Circle()
            .fill(.yellow)
            .frame(width: 6, height: 6)
            .offset(x: 2, y: -2)
            .accessibilityLabel("Settings differ from recommendations")
    }
}
