//
//  GalleryView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/4/23.
//

import SwiftUI

struct GalleryView: View {

    @Environment(GenerationState.self) private var generationState: GenerationState
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(GalleryController.self) private var galleryController: GalleryController
    @Environment(QuickLookState.self) private var quickLook: QuickLookState
    /// Whether the grid is the key view. Gallery key handling hangs off the
    /// grid, so it runs only while the grid holds focus; text fields, sheets and
    /// panels receive their own keys without the gallery having to know about them.
    @FocusState private var isFocused: Bool

    private let gridColumns = [GridItem(.adaptive(minimum: 200), spacing: 16)]
    private var previewLeadsGrid: Bool { store.sortType == .newestFirst }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    if previewLeadsGrid {
                        previewTile
                    }

                    ForEach(store.images) { sdi in
                        tile(for: sdi)
                    }

                    if !previewLeadsGrid {
                        previewTile
                    }
                }
                .padding()
                .background(GalleryScrollbarConfiguration())
            }
            .onChange(of: store.selectedId) { _, selectedId in
                guard let selectedId else { return }
                guard store.images.contains(where: { $0.id == selectedId }) else { return }
                proxy.scrollTo(selectedId)
            }
        }
        .modifier(GalleryKeyHandling(isFocused: $isFocused))
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
        .alert(
            String(
                localized: "Couldn't generate images",
                comment: "Title of the alert shown when a generation produces no image"
            ),
            isPresented: isShowingOutcomeAlert
        ) {
            Button {
                generationState.clearUnreportedOutcomes()
            } label: {
                Text("OK")
            }
        } message: {
            // Blank line between them: these are separate outcomes, not a
            // paragraph, and a batch can end more than one way.
            Text(verbatim: generationState.unreportedOutcomes.joined(separator: "\n\n"))
        }
    }

    private func tile(for sdi: SDImage) -> some View {
        GalleryItemView(sdi: sdi)
            .accessibilityAddTraits(.isButton)
            .transition(.galleryItemTransition)
            .id(sdi.id)
            .aspectRatio(sdi.aspectRatio, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(borderColor(for: sdi), lineWidth: 4)
            )
            .gesture(
                TapGesture(count: 2).onEnded {
                    quickLook.toggle(image: store.selected())
                }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    isFocused = true
                    Task { await galleryController.select(sdi.id) }
                }
            )
            .onDrag {
                Self.dragProvider(for: sdi)
            }
            .contextMenu {
                GalleryItemContextMenuView(sdi: sdi)
            }
    }

    /// The selected tile is accent while the grid has focus and the system's
    /// unemphasized selection otherwise, so the highlight shows whether the
    /// gallery will receive keys.
    private func borderColor(for sdi: SDImage) -> Color {
        guard store.selectedId == sdi.id else {
            return Color(nsColor: .controlBackgroundColor)
        }
        return isFocused
            ? Color.accentColor
            : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    /// Uses ordinary file-transfer metadata for gallery drags so the receiving
    /// image well can preserve the public basename without a Mochi-specific ID.
    /// `suggestedName` is redundant for a well-behaved file-URL consumer, but
    /// some drag destinations ask for image data instead and retain only this
    /// standard piece of provenance.
    static func dragProvider(for sdi: SDImage) -> NSItemProvider {
        if !sdi.path.isEmpty {
            let url = URL(fileURLWithPath: sdi.path)
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = url.lastPathComponent
            return provider
        }

        if let cgImage = sdi.image {
            let nsImage = NSImage(
                cgImage: cgImage,
                size: CGSize(width: sdi.width, height: sdi.height))
            // With no real path there is no public source filename. Offer image
            // data directly so an internal drop does not mistake Mochi's
            // temporary transfer filename for provenance.
            return NSItemProvider(object: nsImage)
        }

        return NSItemProvider()
    }

    /// An outcome arriving while the alert is up joins the one already on screen rather than
    /// queueing another behind it. Dismissing clears the lot.
    private var isShowingOutcomeAlert: Binding<Bool> {
        Binding(
            get: { !generationState.unreportedOutcomes.isEmpty },
            set: { isPresented in
                guard !isPresented else { return }
                generationState.clearUnreportedOutcomes()
            }
        )
    }

    @ViewBuilder
    private var previewTile: some View {
        if let currentImage = store.currentGeneratingImage {
            GalleryPreviewView(image: currentImage)
                .id("generation-preview")
                .transition(.opacity)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(
                            Color(nsColor: .controlBackgroundColor),
                            lineWidth: 4
                        )
                )
        }
    }

    struct GalleryItemContextMenuView: View {
        @Environment(GenerationController.self) private var controller: GenerationController
        @Environment(GalleryController.self) private var galleryController: GalleryController
        let sdi: SDImage

        var body: some View {
            Section {
                Button {
                    Task { await galleryController.copyImage(sdi) }
                } label: {
                    Text(
                        "Copy",
                        comment: "Copy image to the clipboard"
                    )
                }

                Button {
                    Task { await controller.copyToPrompt(sdi) }
                } label: {
                    Text(
                        "Copy Options to Sidebar",
                        comment: "Copy image's generation options to the prompt input sidebar"
                    )
                }

                Button {
                    Task { await controller.useGalleryImage(sdi) }
                } label: {
                    switch controller.galleryImageDestination {
                    case .inputImage:
                        Text(
                            "Set as Input Image",
                            comment: "Use a gallery image as a model reference input"
                        )
                    case .startingImage, .none:
                        Text(
                            "Set as Starting Image",
                            comment: "Use a gallery image as an img2img starting image"
                        )
                    }
                }
                .disabled(controller.galleryImageDestination == nil)
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
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 6)
                        }
                    } label: {
                        Text(
                            "🎈 Red",
                            comment: "Mark this image Red, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 7)
                        }
                    } label: {
                        Text(
                            "🔥 Orange",
                            comment: "Mark this image Orange, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 5)
                        }
                    } label: {
                        Text(
                            "🍋 Yellow",
                            comment: "Mark this image Yellow, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 2)
                        }
                    } label: {
                        Text(
                            "🍀 Green",
                            comment: "Mark this image Green, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 4)
                        }
                    } label: {
                        Text(
                            "💎 Blue",
                            comment: "Mark this image Blue, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 3)
                        }
                    } label: {
                        Text(
                            "🦄 Purple",
                            comment: "Mark this image Purple, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.setFinderTagColorNumber(sdi, colorNumber: 1)
                        }
                    } label: {
                        Text(
                            "🐘 Gray",
                            comment: "Mark this image Gray, with Finder metadata tag"
                        )
                    }
                    Button {
                        Task {
                            galleryController.clearFinderTags(sdi)
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
                    Task { await galleryController.removeImage(sdi) }
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

/// Keyboard control of the gallery selection, attached to the grid so that it
/// runs only while the grid holds focus.
private struct GalleryKeyHandling: ViewModifier {
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(GalleryController.self) private var galleryController: GalleryController
    @Environment(QuickLookState.self) private var quickLook: QuickLookState
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused(isFocused)
            .onMoveCommand(perform: move)
            .onKeyPress(.space) {
                guard let selected = store.selected() else { return .ignored }
                quickLook.toggle(image: selected)
                return .handled
            }
            // Handled here rather than as a menu shortcut: a menu key equivalent is
            // offered to the main menu before the key window's first responder, so
            // it would also fire from a save panel's name field. The Delete key
            // arrives as U+007F, not the U+0008 of `KeyEquivalent.delete`.
            .onKeyPress(KeyEquivalent("\u{7F}"), phases: .down) { press in
                guard press.modifiers == .command, store.selected() != nil else {
                    return .ignored
                }
                Task { await galleryController.removeCurrentImage() }
                return .handled
            }
    }

    private func move(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: Task { await galleryController.selectPrevious() }
        case .right: Task { await galleryController.selectNext() }
        default: break
        }
    }
}

/// Keep a legacy scrollbar's gutter allocated even when the gallery briefly fits.
/// Otherwise AppKit can alternate the viewport width by one scrollbar during
/// split-view layout, repeatedly invalidating SwiftUI's size constraints.
private struct GalleryScrollbarConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigurationView {
        ConfigurationView()
    }

    func updateNSView(_ nsView: ConfigurationView, context: Context) {
        nsView.configureScrollView()
    }

    final class ConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollView()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureScrollView()
        }

        func configureScrollView() {
            guard let scrollView = enclosingScrollView else { return }
            scrollView.autohidesScrollers = false
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
