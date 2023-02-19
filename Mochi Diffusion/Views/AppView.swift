//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @EnvironmentObject private var store: ImageStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            HStack(spacing: 0) {
                GalleryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                InspectorView()
                    .frame(maxWidth: 340)
            }
        }
        .searchable(text: Binding(get: { store.searchText }, set: { store.searchText = $0 }), prompt: "Search")
    }
}

struct AppView_Previews: PreviewProvider {
    static var previews: some View {
        AppView().previewLayout(.sizeThatFits)
            .environmentObject(ImageGenerator.shared)
            .environmentObject(ImageController.shared)
            .environmentObject(ImageStore.shared)
    }
}
