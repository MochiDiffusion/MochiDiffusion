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

    @EnvironmentObject private var controller: ImageController
    @EnvironmentObject private var generator: ImageGenerator
    @EnvironmentObject private var store: ImageStore

    @Binding var config: GalleryConfig

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case let .error(msg) = generator.state {
                ErrorBanner(errorMessage: msg)
            }

            if !store.images.isEmpty {
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
                                                ImageController.shared.copyToPrompt()
                                            } label: {
                                                Text(
                                                    "Copy Options to Sidebar",
                                                    comment: "Copy the currently selected image's generation options to the prompt input sidebar"
                                                )
                                            }
                                            Button {
                                                Task { await ImageController.shared.upscale(sdi) }
                                            } label: {
                                                Text(
                                                    "Convert to High Resolution",
                                                    comment: "Convert the current image to high resolution"
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
                        .quickLookPreview($controller.quicklookURL)
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
        .navigationSubtitle(config.searchText.isEmpty ? "\(store.images.count) image(s)" : "")
        .toolbar {
            GalleryToolbarView()
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
