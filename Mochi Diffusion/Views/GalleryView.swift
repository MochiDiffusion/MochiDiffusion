//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//
// swiftlint:disable line_length

import QuickLook
import SwiftUI

struct GalleryView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var genStore: GeneratorStore
    private var gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = genStore.status {
                ErrorBanner(errorMessage: msg)
            }

            if !genStore.images.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            ForEach(Array(searchResults.enumerated()), id: \.offset) { index, sdi in
                                GalleryItemView(sdi: sdi, index: index)
                                    .accessibilityAddTraits(.isButton)
                                    .onChange(of: genStore.selectedImageIndex) { target in
                                        withAnimation {
                                            proxy.scrollTo(target)
                                        }
                                    }
                                    .aspectRatio(sdi.aspectRatio, contentMode: .fit)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(
                                                index == genStore.selectedImageIndex ?
                                                Color.accentColor :
                                                    Color(nsColor: .controlBackgroundColor),
                                                lineWidth: 4
                                            )
                                    )
                                    .gesture(TapGesture(count: 2).onEnded {
                                        genStore.quicklookCurrentImage()
                                    })
                                    .simultaneousGesture(TapGesture().onEnded {
                                        genStore.selectImage(index: index)
                                    })
                                    .contextMenu {
                                        Section {
                                            Button(action: genStore.copyToPrompt) {
                                                Text(
                                                    "Copy Options to Sidebar",
                                                    comment: "Copy the currently selected image's generation options to the prompt input sidebar"
                                                )
                                            }
                                            Button {
                                                genStore.upscaleImage(sdi: sdi)
                                            } label: {
                                                Text(
                                                    "Convert to High Resolution",
                                                    comment: "Convert the current image to high resolution"
                                                )
                                            }
                                            Button(action: sdi.save) {
                                                Text(
                                                    "Save As...",
                                                    comment: "Show the save image dialog"
                                                )
                                            }
                                        }
                                        Section {
                                            Button {
                                                genStore.removeImage(index: index)
                                            } label: {
                                                Text(
                                                    "Remove",
                                                    comment: "Remove image from the gallery"
                                                )
                                            }
                                        }
                                    }
                            }
                        }
                        .quickLookPreview($genStore.quicklookURL)
                        .padding()
                    }
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
            genStore.searchText.isEmpty ?
                "Mochi Diffusion" :
                String(
                    localized: "Searching: \(genStore.searchText)",
                    comment: "Window title bar label displaying the searched text"
                )
        )
        .navigationSubtitle(genStore.searchText.isEmpty ? "^[\(genStore.images.count) images](inflect: true)" : "")
        .toolbar {
            GalleryToolbarView()
        }
    }

    var searchResults: [SDImage] {
        if $genStore.searchText.wrappedValue.isEmpty {
            return genStore.images
        }
        return genStore.images.filter { $0.prompt.lowercased().contains(genStore.searchText.lowercased())
        }
    }
}
