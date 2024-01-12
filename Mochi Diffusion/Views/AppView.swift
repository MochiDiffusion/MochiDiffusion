//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @EnvironmentObject private var store: ImageStore
    @State private var isShowingInspector = true

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 450)
        } detail: {
            GalleryView()
                .inspector(isPresented: $isShowingInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 300, max: 400)
                }
        }
        .toolbar {
            GalleryToolbarView(isShowingInspector: $isShowingInspector)
        }
        .searchable(text: $store.searchText, prompt: "Search")
    }
}

struct AppView_Previews: PreviewProvider {
    static var previews: some View {
        AppView().previewLayout(.sizeThatFits)
            .environmentObject(ImageStore.shared)
    }
}
