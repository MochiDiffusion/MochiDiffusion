//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import QuickLook
import SwiftUI

struct GalleryView: View {

    @Environment(\.colorScheme) private var colorScheme

    @Binding var config: GalleryConfig

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = ImageController.shared.state {
                ErrorBanner(errorMessage: msg)
            }

            if !ImageController.shared.images.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: gridColumns, spacing: 16) {
                            ForEach(Array(ImageController.shared.images.enumerated()), id: \.offset) { index, sdi in
                                GalleryItemView(sdi: sdi, index: index)
                                    .accessibilityAddTraits(.isButton)
                                    .onChange(of: ImageController.shared.selectedImageIndex) { target in
                                        withAnimation {
                                            proxy.scrollTo(target)
                                        }
                                    }
                                    .aspectRatio(sdi.aspectRatio, contentMode: .fit)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(
                                                index == ImageController.shared.selectedImageIndex ?
                                                Color.accentColor :
                                                    Color(nsColor: .controlBackgroundColor),
                                                lineWidth: 4
                                            )
                                    )
                                    .gesture(TapGesture(count: 2).onEnded {
                                        config.quicklookCurrentImage()
                                    })
                                    .simultaneousGesture(TapGesture().onEnded {
                                        ImageController.shared.selectedImageIndex = index
                                    })
                                    .contextMenu {
                                        Section {
                                            Button {

                                            } label: {
                                                Text(
                                                    "Copy Options to Sidebar",
                                                    comment: "Copy the currently selected image's generation options to the prompt input sidebar"
                                                )
                                            }
                                            Button {
                                                Task { await ImageController.shared.upscale(sdi: sdi) }
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
                                                Task { await ImageController.shared.removeImage(index) }
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
                        .quickLookPreview($config.quicklookURL)
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
            config.searchText.isEmpty ?
                "Mochi Diffusion" :
                String(
                    localized: "Searching: \(config.searchText)",
                    comment: "Window title bar label displaying the searched text"
                )
        )
        .navigationSubtitle(config.searchText.isEmpty ? "\(ImageController.shared.images.count) image(s)" : "")
        .toolbar {
            GalleryToolbarView()
        }
    }
}
