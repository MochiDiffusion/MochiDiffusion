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
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            HStack(spacing: 0) {
                GalleryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                if isShowingInspector {
                    InspectorView()
                        .frame(maxWidth: 340)
                }
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
