//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @State private var galleryConfig = GalleryConfig()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            HStack(spacing: 0) {
                GalleryView(config: $galleryConfig)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                InspectorView()
                    .frame(maxWidth: 340)
            }
        }
        .searchable(text: $galleryConfig.searchText, prompt: "Search")
    }
}

struct AppView_Previews: PreviewProvider {
    static var previews: some View {
        AppView().previewLayout(.sizeThatFits)
    }
}
