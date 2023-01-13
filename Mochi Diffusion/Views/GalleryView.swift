//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//
// swiftlint:disable line_length

import SwiftUI
import QuickLook

struct GalleryView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var store: Store
    @State private var quicklookImage: URL?
    private var gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = store.mainViewStatus {
                ErrorBanner(errorMessage: msg)
            }

            if store.images.count > 0 {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(Array(searchResults.enumerated()), id: \.offset) { index, sdi in
                            GeometryReader { geo in
                                GalleryItemView(width: geo.size.width, height: geo.size.height, sdi: sdi, index: index)
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(
                                        index == store.selectedImageIndex ?
                                            Color.accentColor :
                                            Color(nsColor: .controlBackgroundColor),
                                        lineWidth: 4)
                            )
                            .gesture(TapGesture(count: 2).onEnded {
                                quicklookImage = try? sdi.image?.asNSImage().temporaryFileURL()
                            })
                            .simultaneousGesture(TapGesture().onEnded {
                                store.selectImage(index: index)
                                // If quicklook is open show selected image on single click
                                if quicklookImage != nil {
                                    quicklookImage = try? sdi.image?.asNSImage().temporaryFileURL()
                                }
                            })
                            .contextMenu {
                                Section {
                                    Button(action: store.copyToPrompt) {
                                        Text("Copy Options to Sidebar",
                                             comment: "Button to copy the currently selected image's generation options to the prompt input sidebar")
                                    }
                                    Button {
                                        store.upscaleImage(sdImage: sdi)
                                    } label: {
                                        Text("Convert to High Resolution",
                                             comment: "Right click menu option to convert the image to high resolution")
                                    }
                                    Button(action: sdi.save) {
                                        Text("Save As...",
                                             comment: "Right click menu option to show the save image dialog")
                                    }
                                }
                                Section {
                                    Button {
                                        store.removeImage(index: index)
                                    } label: {
                                        Text("Remove",
                                             comment: "Right click menu option to remove image from the gallery")
                                    }
                                }
                            }
                        }
                    }
                    .quickLookPreview($quicklookImage)
                    .padding()
                }
            } else {
                Color.clear
            }
        }
        .background(
            Image(systemName: "circle.fill")
                .resizable(resizingMode: .tile)
                .foregroundColor(Color.black.opacity(colorScheme == .dark ? 0.05 : 0.02))
        )
        .navigationTitle(
            store.searchText.isEmpty ?
                "Mochi Diffusion" :
                String(localized: "Searching: \(store.searchText)",
                       comment: "Window title bar label displaying the searched text"))
        .navigationSubtitle(store.searchText.isEmpty ? "^[\(store.images.count) images](inflect: true)" : "")
        .toolbar {
            GalleryToolbarView()
        }
    }

    var searchResults: [SDImage] {
        if $store.searchText.wrappedValue.isEmpty {
            return store.images
        }
        return store.images.filter { $0.prompt.lowercased().contains(store.searchText.lowercased())
        }
    }
}
