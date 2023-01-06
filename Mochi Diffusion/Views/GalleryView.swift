//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI
import QuickLook

struct GalleryView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var store: Store
    @State private var quicklookImage: URL? = nil
    private var gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    
    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = store.mainViewStatus {
                ErrorBanner(errorMessage: msg)
            }
            
            if store.images.count > 0 {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { i, sdi in
                            GeometryReader { geo in
                                GalleryItemView(size: geo.size.width, sdi: sdi, i: i)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(i == store.selectedImageIndex ? Color.accentColor : Color(nsColor: .controlBackgroundColor), lineWidth: 4)
                            )
                            .gesture(TapGesture(count: 2).onEnded {
                                quicklookImage = try? sdi.image?.asNSImage().temporaryFileURL()
                            })
                            .simultaneousGesture(TapGesture().onEnded {
                                store.selectImage(index: i)
                                // If quicklook is open show selected image on single click
                                if quicklookImage != nil {
                                    quicklookImage = try? sdi.image?.asNSImage().temporaryFileURL()
                                }
                            })
                            .contextMenu {
                                Section {
                                    Button(action: store.copyToPrompt) {
                                        Text("Copy Options to Sidebar",
                                             tableName: "Gallery",
                                             comment: "Button to copy the currently selected image's generation options to the prompt input sidebar")
                                    }
                                    Button(action: { store.upscaleImage(sdImage: sdi) }) {
                                        Text("Convert to High Resolution",
                                             tableName: "Gallery",
                                             comment: "Right click menu option to convert the image to high resolution")
                                    }
                                    Button(action: sdi.save) {
                                        Text("Save As...",
                                             tableName: "Gallery",
                                             comment: "Right click menu option to show the save image dialog")
                                    }
                                }
                                Section {
                                    Button(action: { store.removeImage(index: i) }) {
                                        Text("Remove",
                                             tableName: "Gallery",
                                             comment: "Right click menu option to remove image from the gallery")
                                    }
                                }
                            }
                        }
                    }
                    .quickLookPreview($quicklookImage)
                    .padding()
                }
            }
            else {
                Color.clear
            }
        }
        .background(
            Image(systemName: "circle.fill")
                .resizable(resizingMode: .tile)
                .foregroundColor(Color.black.opacity(colorScheme == .dark ? 0.05 : 0.02))
        )
        .navigationTitle(store.searchText.isEmpty ? "Mochi Diffusion" : "Searching: \(store.searchText)")
        .navigationSubtitle(store.searchText.isEmpty ? "^[\(store.images.count) images](inflect: true)" : "")
        .toolbar {
            GalleryToolbarView()
        }
    }
    
    var searchResults: [SDImage] {
        if $store.searchText.wrappedValue.isEmpty {
            return store.images
        }
        return store.images.filter { $0.prompt.contains(store.searchText) }
    }
}
