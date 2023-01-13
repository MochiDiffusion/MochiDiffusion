//
//  AppView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/22.
//

import SwiftUI

struct AppView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        NavigationSplitView {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    Group {
                        PromptView()
                        Divider().frame(height: 16)
                    }
                    Group {
                        NumberOfBatchesView()
                        Spacer()
                    }
                    Group {
                        BatchSizeView()
                        Spacer()
                    }
                    Group {
                        StepsView()
                        Spacer()
                    }
                    Group {
                        GuidanceScaleView()
                        Spacer()
                    }
                    Group {
                        SeedView()
                        Spacer()
                    }
                    Group {
                        ModelView()
                    }
                }
                .padding([.horizontal, .bottom])
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        } detail: {
            HStack(alignment: .center, spacing: 0) {
                GalleryView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                InspectorView()
                    .frame(maxWidth: 340)
            }
        }
        .searchable(text: $store.searchText, prompt: "Search")
    }
}

struct AppView_Previews: PreviewProvider {
    static var previews: some View {
        AppView().previewLayout(.sizeThatFits)
    }
}
