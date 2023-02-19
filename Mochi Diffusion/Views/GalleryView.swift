//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryView: View {

    @Environment(\.colorScheme) private var colorScheme

    @EnvironmentObject private var generator: ImageGenerator
    @EnvironmentObject private var store: ImageStore

    @State private var filteredImages: [SDImage] = []
    @Binding var searchText: String

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = generator.state {
                ErrorBanner(errorMessage: msg)
            }

            if !filteredImages.isEmpty {
                galleryView
            } else {
                emptyGalleryView
            }
        }
        .onReceive(store.$images) { updateFilteredImages($0, searchText) }
        .onChange(of: searchText) { updateFilteredImages(store.images, $0) }
        .background(
            Image(systemName: "circle.fill")
                .resizable(resizingMode: .tile)
                .foregroundColor(Color.black.opacity(colorScheme == .dark ? 0.05 : 0.02))
        )
        .navigationTitle(
            searchText.isEmpty ?
                "Mochi Diffusion" :
                String(
                    localized: "Searching: \(searchText)",
                    comment: "Window title bar label displaying the searched text"
                )
        )
        .navigationSubtitle("\(filteredImages.count) image(s)")
        .toolbar {
            GalleryToolbarView()
        }
    }

    @ViewBuilder
    private var galleryView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(filteredImages) { sdi in
                        GalleryItemView(sdi: sdi)
                            .accessibilityAddTraits(.isButton)
                            .transition(.niceFade)
                            .onChange(of: store.selected()) { target in
                                if let sdi = target {
                                    withAnimation {
                                        proxy.scrollTo(sdi.id)
                                    }
                                }
                            }
                            .aspectRatio(sdi.aspectRatio, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(
                                        sdi.isSelected ?
                                        Color.accentColor :
                                            Color(nsColor: .controlBackgroundColor),
                                        lineWidth: 4
                                    )
                            )
                            .gesture(TapGesture(count: 2).onEnded {
                                Task { await ImageController.shared.quicklookCurrentImage() }
                            })
                            .simultaneousGesture(TapGesture().onEnded {
                                Task { await ImageController.shared.select(sdi.id) }
                            })
                            .contextMenu {
                                Section {
                                    Button {
                                        Task { await ImageController.shared.copyImage() }
                                    } label: {
                                        Text(
                                            "Copy",
                                            comment: "Copy the currently selected image to the clipboard"
                                        )
                                    }
                                    Button {
                                        ImageController.shared.copyToPrompt()
                                    } label: {
                                        Text(
                                            "Copy Options to Sidebar",
                                            comment: "Copy the currently selected image's generation options to the prompt input sidebar"
                                        )
                                    }
                                    Button {
                                        Task { await sdi.save() }
                                    } label: {
                                        Text(
                                            "Save As...",
                                            comment: "Show the save image dialog"
                                        )
                                    }
                                }
                                if sdi.upscaler.isEmpty {
                                    Section {
                                        Button {
                                            Task { await ImageController.shared.upscale(sdi) }
                                        } label: {
                                            Text(
                                                "Convert to High Resolution",
                                                comment: "Convert the current image to high resolution"
                                            )
                                        }
                                    }
                                }
                                Section {
                                    Button {
                                        Task { await ImageController.shared.removeImage(sdi) }
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
                .padding()
            }
        }
    }

    @ViewBuilder
    private var emptyGalleryView: some View {
        Color.clear
    }

    private func updateFilteredImages(_ images: [SDImage], _ searchText: String) {
        if searchText.isEmpty {
            filteredImages = images
        } else {
            filteredImages = images.filter(searchText)
        }
    }
}

extension AnyTransition {
    static var niceFade: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale.combined(with: .opacity)
        )
    }
}

private extension Array where Element == SDImage {
    func filter(_ text: String) -> [SDImage] {
        self.filter {
            $0.prompt.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil ||
            $0.seed == UInt32(text)
        }
    }
}
