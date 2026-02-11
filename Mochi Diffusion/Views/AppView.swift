//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(QuickLookState.self) private var quickLook: QuickLookState
    @State private var isShowingInspector = true

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 450)
        } detail: {
            GalleryView()
                .inspector(isPresented: $isShowingInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 300, max: 500)
                }
        }
        .toolbar {
            GalleryToolbarView(isShowingInspector: $isShowingInspector)
        }
        .onChange(of: self.store.selectedId) { _, newValue in
            guard newValue != nil else {
                quickLook.close()
                return
            }
            quickLook.updateSelection(self.store.selected())
        }
    }
}

#Preview {
    let focusController = FocusController()
    AppView()
        .environment(GenerationController(configStore: ConfigStore()))
        .environment(
            GalleryController(
                configStore: ConfigStore(),
                focusController: focusController
            )
        )
        .environment(ConfigStore())
        .environment(focusController)
        .environment(GenerationState.shared)
        .environment(ImageGallery.shared)
        .environment(QuickLookState())
}
