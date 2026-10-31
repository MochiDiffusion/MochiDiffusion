//
//  GalleryToolbarView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import AppKit
import SwiftUI

struct GalleryToolbarView: View {
    @Environment(GenerationState.self) private var generationState: GenerationState
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(GalleryController.self) private var galleryController: GalleryController
    @Environment(GenerationController.self) private var generationController: GenerationController
    @Environment(ConfigStore.self) private var configStore: ConfigStore
    @Binding var isShowingInspector: Bool
    @State private var queuePopover = DetachablePopover()

    var body: some View {
        @Bindable var store = store

        ZStack {
            if case .running(let progress) = generationState.state, let progress = progress,
                progress.stepCount > 0
            {
                let step = progress.step + 1
                let stepValue = Double(step) / Double(progress.stepCount)

                queueButton {
                    CircularProgressView(progress: stepValue)
                }
            } else if case .loading(_) = generationState.state {
                queueButton {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            } else if case .canceling(_) = generationState.state {
                queueButton {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
            }
        }
        // On the ZStack rather than a button, so moving between loading and running
        // keeps the same anchor. The popover outlives it: dragged off into a window, the
        // queue stays open after generation finishes and the button hides.
        .background(
            PopoverAnchor(popover: queuePopover) {
                JobQueueView()
                    .frame(width: 420, height: 240)
                    .environment(generationState)
                    .environment(generationController)
                    .environment(configStore)
            }
        )

        Picker("Sort", selection: $store.sortType) {
            Text(
                "Oldest First",
                comment: "Picker option to sort images in the gallery from oldest to newest"
            ).tag(ImagesSortType.oldestFirst)

            Text(
                "Newest First",
                comment: "Picker option to sort images in the gallery from newest to oldest"
            )
            .tag(ImagesSortType.newestFirst)
        }

        // Gated on there being a selection, not on its pixels being in memory: a
        // gallery image loaded from disk has no decoded image.
        if let sdi = store.selected() {
            Button {
                Task { await galleryController.removeCurrentImage() }
            } label: {
                Label {
                    Text(
                        "Remove",
                        comment: "Toolbar button to remove the selected image"
                    )
                } icon: {
                    Image(systemName: "trash")
                }
                .help("Remove")
            }

            Spacer()

            Button {
                Task { await sdi.saveAs() }
            } label: {
                Label {
                    Text(
                        "Save As...",
                        comment: "Toolbar button to show the save image dialog"
                    )
                } icon: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save As...")
            }
            shareLink(for: sdi)
        } else {
            disabledToolbarActionView
        }

        Button {
            isShowingInspector.toggle()
        } label: {
            Label {
                Text(
                    "Toggle Info Panel",
                    comment: "Toolbar button to hide or show the info panel"
                )
            } icon: {
                Image(systemName: "sidebar.right")
            }
        }

        FilterTextFieldView(filters: $store.filters)
            .frame(minWidth: 300)
            .frame(maxWidth: 500)
            .frame(height: 40)
    }

    private func queueButton(@ViewBuilder label: () -> some View) -> some View {
        Button {
            queuePopover.toggle()
        } label: {
            label()
                .frame(width: 16, height: 16)
        }
    }

    /// Shares the file when there is one, and the pixels when there is not.
    ///
    /// The file is the better thing to share regardless — it carries the image's
    /// metadata, which an `Image` rendered from a `CGImage` does not — and it is the
    /// only option for a gallery image that was never decoded.
    @ViewBuilder private func shareLink(for sdi: SDImage) -> some View {
        if !sdi.path.isEmpty {
            ShareLink(item: URL(fileURLWithPath: sdi.path, isDirectory: false))
                .help("Share...")
        } else if let image = sdi.image {
            let imageView = Image(image, scale: 1, label: Text(verbatim: sdi.prompt))
            ShareLink(item: imageView, preview: SharePreview(sdi.prompt, image: imageView))
                .help("Share...")
        } else {
            Button {
                // noop
            } label: {
                Label {
                    Text("Share...", comment: "Toolbar button to show the system share sheet")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .disabled(true)
        }
    }

    @ViewBuilder private var disabledToolbarActionView: some View {
        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Remove",
                    comment: "Toolbar button to remove the selected image"
                )
            } icon: {
                Image(systemName: "trash")
            }
        }
        .disabled(true)

        Spacer()

        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Save As...",
                    comment: "Toolbar button to show the save image dialog"
                )
            } icon: {
                Image(systemName: "square.and.arrow.down")
            }
        }
        .disabled(true)

        Button {
            // noop
        } label: {
            Label {
                Text(
                    "Share...",
                    comment: "Toolbar button to show the system share sheet"
                )
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(true)
    }
}

/// An `NSPopover` that, unlike SwiftUI's `.popover`, can be dragged off its anchor
/// into a floating window, which stays open until closed.
///
/// It is owned apart from its anchor so that a detached window survives the anchor
/// being removed; an attached popover closes with its anchor.
private final class DetachablePopover: NSObject, NSPopoverDelegate {
    private(set) lazy var hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self
        return popover
    }()
    weak var anchor: NSView?
    private var isDetached = false

    /// Shows the attached popover, closes it, or brings the detached window forward.
    func toggle() {
        if isDetached {
            hostingController.view.window?.makeKeyAndOrderFront(nil)
        } else if popover.isShown {
            popover.close()
        } else if let anchor {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    /// Called when `view` leaves the view hierarchy.
    func anchorRemoved(_ view: NSView) {
        guard anchor === view else { return }
        anchor = nil
        if !isDetached, popover.isShown {
            popover.close()
        }
    }

    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        true
    }

    func popoverDidDetach(_ popover: NSPopover) {
        isDetached = true
    }

    /// Keeps a click on the anchor from closing the popover, so the anchor's own
    /// action closes it rather than closing and immediately reopening it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let anchor, !isDetached, let event = NSApp.currentEvent,
            event.type == .leftMouseDown, event.window === anchor.window
        else {
            return true
        }
        let location = anchor.convert(event.locationInWindow, from: nil)
        return !anchor.bounds.contains(location)
    }

    func popoverDidClose(_ notification: Notification) {
        isDetached = false
    }
}

/// Positions a `DetachablePopover` on the view it backs and supplies its content.
private struct PopoverAnchor<Content: View>: NSViewRepresentable {
    let popover: DetachablePopover
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> DetachablePopover {
        popover
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        popover.anchor = nsView
        popover.hostingController.rootView = AnyView(content())
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: DetachablePopover) {
        coordinator.anchorRemoved(nsView)
    }
}
