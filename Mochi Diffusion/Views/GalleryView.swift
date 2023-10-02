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
                MessageBanner(message: msg)
            } else if case let .ready(msg) = generator.state, let msg = msg {
                MessageBanner(message: msg)
            }

            if !store.images.isEmpty || store.currentGeneratingImage != nil {
                galleryView
            } else {
                emptyGalleryView
            }
        }
        .background(
            Image("GalleryBackground")
                .resizable(resizingMode: .tile)
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
    }

    @ViewBuilder
    private var galleryView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    if store.sortType == .newestFirst {
                        if let currentImage = store.currentGeneratingImage, case .running = generator.state {
                            GalleryPreviewView(image: currentImage)
                        }
                    }

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
                                GalleryItemContextMenuView(sdi: sdi)
                            }
                    }

                    if store.sortType == .oldestFirst {
                        if let currentImage = store.currentGeneratingImage, case .running = generator.state {
                            GalleryPreviewView(image: currentImage)
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

    struct GalleryItemContextMenuView: View {
        let sdi: SDImage

        var body: some View {
            Section {
                Button {
                    Task { await ImageController.shared.copyImage(sdi) }
                } label: {
                    Text(
                        "Copy",
                        comment: "Copy image to the clipboard"
                    )
                }

                Button {
                    ImageController.shared.copyToPrompt(sdi)
                } label: {
                    Text(
                        "Copy Options to Sidebar",
                        comment: "Copy image's generation options to the prompt input sidebar"
                    )
                }

                Button {
                    Task { await ImageController.shared.selectStartingImage(sdi: sdi) }
                } label: {
                    Text("Set as Starting Image")
                }
            }
            if sdi.upscaler.isEmpty {
                Section {
                    Button {
                        Task { await ImageController.shared.upscale(sdi) }
                    } label: {
                        Text(
                            "Convert to High Resolution",
                            comment: "Convert image to high resolution"
                        )
                    }
                }
            }
            Section {
                Button {
                    Task { await sdi.saveAs() }
                } label: {
                    Text(
                        "Save As...",
                        comment: "Show the save image dialog"
                    )
                }

                if !sdi.path.isEmpty {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: sdi.path).absoluteURL])
                    } label: {
                        Text(
                            "Show in Finder",
                            comment: "Show image with Finder"
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

extension AnyTransition {
    static var niceFade: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale.combined(with: .opacity)
        )
    }
}
