//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryView: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(ImageGenerator.self) private var generator: ImageGenerator
    @Environment(ImageStore.self) private var store: ImageStore

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            if case .error(let msg) = generator.state {
                MessageBanner(message: msg)
            } else if case .ready(let msg) = generator.state, let msg = msg {
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
            store.filters.isEmpty
                ? "Mochi Diffusion"
                : String(
                    localized: "Filtering: \(store.filters.humanReadable())",
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
                        if let currentImage = store.currentGeneratingImage,
                            case .running = generator.state
                        {
                            GalleryPreviewView(image: currentImage)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            Color(nsColor: .controlBackgroundColor),
                                            lineWidth: 4
                                        )
                                )
                        }
                    }

                    ForEach(store.images) { sdi in
                        GalleryItemView(sdi: sdi)
                            .accessibilityAddTraits(.isButton)
                            .transition(.galleryItemTransition)
                            .onChange(of: store.selected()) {
                                if let sdi = store.selected() {
                                    withAnimation {
                                        proxy.scrollTo(sdi.id)
                                    }
                                }
                            }
                            .aspectRatio(sdi.aspectRatio, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(
                                        store.selectedId == sdi.id
                                            ? Color.accentColor
                                            : Color(nsColor: .controlBackgroundColor),
                                        lineWidth: 4
                                    )
                            )
                            .gesture(
                                TapGesture(count: 2).onEnded {
                                    Task { await ImageController.shared.quicklookCurrentImage() }
                                }
                            )
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    Task { await ImageController.shared.select(sdi.id) }
                                }
                            )
                            .onDrag {
                                if !sdi.path.isEmpty,
                                    let item = NSItemProvider(
                                        contentsOf: URL(fileURLWithPath: sdi.path))
                                {
                                    return item
                                }

                                if let cgImage = sdi.image {
                                    let nsImage = NSImage(
                                        cgImage: cgImage,
                                        size: CGSize(width: sdi.width, height: sdi.height))
                                    if let tempURL = try? nsImage.temporaryFileURL(),
                                        let item = NSItemProvider(contentsOf: tempURL)
                                    {
                                        return item
                                    }
                                }

                                return NSItemProvider()
                            }
                            .contextMenu {
                                GalleryItemContextMenuView(sdi: sdi)
                            }
                    }

                    if store.sortType == .oldestFirst {
                        if let currentImage = store.currentGeneratingImage,
                            case .running = generator.state
                        {
                            GalleryPreviewView(image: currentImage)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(
                                            Color(nsColor: .controlBackgroundColor),
                                            lineWidth: 4
                                        )
                                )
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
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: sdi.path).absoluteURL
                        ])
                    } label: {
                        Text(
                            "Show in Finder",
                            comment: "Show image with Finder"
                        )
                    }
                }
            }
            Section {
                Menu("Tags") {
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 6)
                        }
                    } label: {
                        Text(
                            "🎈 Red",
                            comment: "Mark this image Red, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 7)
                        }
                    } label: {
                        Text(
                            "🔥 Orange",
                            comment: "Mark this image Orange, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 5)
                        }
                    } label: {
                        Text(
                            "🍋 Yellow",
                            comment: "Mark this image Yellow, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 2)
                        }
                    } label: {
                        Text(
                            "🍀 Green",
                            comment: "Mark this image Green, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 4)
                        }
                    } label: {
                        Text(
                            "💎 Blue",
                            comment: "Mark this image Blue, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 3)
                        }
                    } label: {
                        Text(
                            "🦄 Purple",
                            comment: "Mark this image Purple, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            setFinderTagColorNumber(sdi, colorNumber: 1)
                        }
                    } label: {
                        Text(
                            "🐘 Gray",
                            comment: "Mark this image Gray, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            clearFinderTags(sdi)
                        }
                    } label: {
                        Text(
                            "Clear All",
                            comment: "Clear all Finder metadata color tags"
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
    static var galleryItemTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity,
            removal: .scale.combined(with: .opacity)
        )
    }
}
