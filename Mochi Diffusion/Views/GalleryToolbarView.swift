//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import SwiftUI

struct GalleryToolbarView: View {
    @Binding var isShowingInspector: Bool
    @EnvironmentObject private var generator: ImageGenerator
    @EnvironmentObject private var store: ImageStore
    @EnvironmentObject private var controller: ImageController
    @State private var isStatusPopoverShown = false

    var body: some View {
        Group {
            Button {
                self.isStatusPopoverShown.toggle()
            } label: {
                if case let .running(progress) = generator.state, let progress = progress {
                    ToolbarCircularProgressView(progress)
                } else if case .loading = generator.state {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.borderless)
        }
        .popover(isPresented: self.$isStatusPopoverShown, arrowEdge: .bottom) {
            JobQueueView()
                .frame(width: 420, height: 240)
        }

        Picker("Sort", selection: $store.sortType) {
            Text(
                "Oldest First",
                comment: "Picker option to sort images in the gallery from oldest to newest"
            ).tag(ImagesSortType.oldestFirst)

            Text(
                "Newest First",
                comment: "Picker option to sort images in the gallery from newest to oldest"
            )
            .tag(ImagesSortType.newestFirst)
        }

        Group {
            toolbarActionsView

            if let sdi = store.selected(), let img = sdi.image {
                let imageView = Image(img, scale: 1, label: Text(verbatim: sdi.prompt))
                ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                    .help("Share...")
            } else {
                Button("Share...", systemImage: "square.and.arrow.up") {}
                    .disabled(true)
            }
        }
        Button {
            withAnimation {
                isShowingInspector.toggle()
            }
        } label: {
            Label {
                Text(
                    "Toggle Info Panel",
                    comment: "Toolbar button to hide or show the info panel"
                )
            } icon: {
                Image(systemName: "sidebar.right")
            }
        }
    }

    @ViewBuilder
    private func ToolbarCircularProgressView(_ progress: StableDiffusionProgress) -> some View {
        let step = Int(progress.step) + 1
        let stepValue = Double(step) / Double(progress.stepCount)
        ZStack {
            CircularProgressView(progress: stepValue)
                .frame(width: 16, height: 16)
            Group {
                if !controller.generationQueue.isEmpty {
                    Text("\(controller.generationQueue.count + 1)")
                        .font(.caption2)
                }
            }
        }
    }

    // ToolbarAction allows us to enumerate among all buttons
    private enum ToolbarAction: CaseIterable {
        case remove, convertToHighRes, saveAs

        var title: String {
            switch self {
            case .remove:
                return "Remove"
            case .convertToHighRes:
                return "Convert to High Resolution"
            case .saveAs:
                return "Save As..."
            }
        }

        var systemImageName: String {
            switch self {
            case .remove:
                return "trash"
            case .convertToHighRes:
                return "wand.and.stars"
            case .saveAs:
                return "square.and.arrow.down"
            }
        }

        var helpText: String {
            switch self {
            case .remove:
                return "Remove the selected image"
            case .convertToHighRes:
                return "Convert the selected image to high resolution"
            case .saveAs:
                return "Save the selected image"
            }
        }
    }

    // Single Tool Bar Button
    private struct ToolBarButton: View {
        var action: ToolbarAction
        var isEnabled: Bool
        var performAction: (() async -> Void)?

        var body: some View {
            Button {
                if isEnabled, let performAction = performAction {
                    Task {
                        await performAction()
                    }
                }
            } label: {
                Label {
                    Text(action.title)
                } icon: {
                    Image(systemName: action.systemImageName)
                }
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.5)
            .help(action.helpText)
        }
    }

    // All Tool Bar Buttons (looping through them)
    @ViewBuilder
    private var toolbarActionsView: some View {
        ForEach(ToolbarAction.allCases, id: \.self) { action in
            let isEnabled = determineIfEnabled(for: action)
            let actionToPerform = getAction(for: action)

            ToolBarButton(action: action, isEnabled: isEnabled, performAction: actionToPerform)
        }
    }

    // Determining if toolbar button can be used
    private func determineIfEnabled(for action: ToolbarAction) -> Bool {
        switch action {
        case .convertToHighRes,
             .remove,
             .saveAs:
            return store.selected() != nil
        }
    }

    // Getting toolbar action.
    private func getAction(for action: ToolbarAction) -> (() async -> Void)? {
        switch action {
        case .remove:
            return { await ImageController.shared.removeCurrentImage() }
        case .convertToHighRes:
            return { await ImageController.shared.upscaleCurrentImage() }
        case .saveAs:
            if let sdi = store.selected() {
                return { await sdi.saveAs() }
            } else {
                return nil
            }
        }
    }
}

struct GalleryToolbarView_Previews: PreviewProvider {
    static var previews: some View {
        HStack {
            GalleryToolbarView(isShowingInspector: .constant(true))
                .environmentObject(ImageGenerator.shared)
                .environmentObject(ImageStore.shared)
        }
    }
}
