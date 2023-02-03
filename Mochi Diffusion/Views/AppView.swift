//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @EnvironmentObject private var genStore: GeneratorStore

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
        .searchable(text: $genStore.searchText, prompt: "Search")
    }
}

struct AppView_Previews: PreviewProvider {
    static let genStore = GeneratorStore()
    
    static var previews: some View {
        AppView().previewLayout(.sizeThatFits)
            .environmentObject(genStore)
    }
}
