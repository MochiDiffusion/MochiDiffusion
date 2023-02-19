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

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = generator.state {
                ErrorBanner(errorMessage: msg)
            }

            if !store.images.isEmpty {
                galleryView
            } else {
                emptyGalleryView
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
                String(
                    localized: "Searching: \(store.searchText)",
                    comment: "Window title bar label displaying the searched text"
                )
        )
        .navigationSubtitle("\(store.images.count) image(s)")
        .toolbar {
            GalleryToolbarView()
        }
    }

    @ViewBuilder
    private var galleryView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(store.images) { sdi in
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
                                        store.selectedId == sdi.id ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
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
}

extension AnyTransition {
    static var niceFade: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale.combined(with: .opacity)
        )
    }
}
