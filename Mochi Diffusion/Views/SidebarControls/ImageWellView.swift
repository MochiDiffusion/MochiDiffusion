//
//  ImageWellView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-07.
//

import SwiftUI
import UniformTypeIdentifiers

/// Imports a file-backed image when possible so its basename can survive.
/// Image bytes remain an anonymous fallback for sources such as browsers and Photos.
struct ImageDropTransfer: Transferable {
    enum Storage: Sendable {
        case imageFile(data: Data, filename: String?, isOriginal: Bool)
        case imageData(Data)
    }

    let storage: Storage

    nonisolated static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(
            importedContentType: .image,
            shouldAttemptToOpenInPlace: true
        ) { received in
            // A received file is only guaranteed to exist inside this closure.
            // Keep its bytes and whether macOS gave us the actual source file;
            // only an original file has trustworthy basename provenance.
            let data = try Data(contentsOf: received.file)
            let filename = received.file.lastPathComponent.normalizedFilename
            return Self(
                storage: .imageFile(
                    data: data,
                    filename: filename,
                    isOriginal: received.isOriginalFile
                )
            )
        }

        DataRepresentation(importedContentType: .image) { data in
            Self(storage: .imageData(data))
        }
    }
}

struct ImageWellView: View {
    typealias DroppedImage = (image: CGImage, filename: String?)

    var image: CGImage?
    let widthModifier: Double
    let heightModifier: Double
    let selectImage: () async -> CGImage?
    let setImages: (@Sendable ([DroppedImage]) async -> Void)?
    let maximumDropCount: Int?
    let removeImage: (@Sendable () async -> Void)?
    let removeHelp: String?
    let setImage: @Sendable (DroppedImage) async -> Void

    init(
        image: CGImage? = nil,
        size: CGSize?,
        selectImage: @escaping () async -> CGImage?,
        setImages: (@Sendable ([DroppedImage]) async -> Void)? = nil,
        maximumDropCount: Int? = nil,
        removeImage: (@Sendable () async -> Void)? = nil,
        removeHelp: String? = nil,
        setImage: @escaping @Sendable (DroppedImage) async -> Void
    ) {
        self.image = image
        if let width = size?.width, let height = size?.height {
            let aspectRatio = width / height
            self.widthModifier = aspectRatio < 1.0 ? aspectRatio : 1.0
            self.heightModifier = aspectRatio > 1.0 ? 1 / aspectRatio : 1.0
        } else {
            self.widthModifier = 1.0
            self.heightModifier = 1.0
        }
        self.selectImage = selectImage
        self.setImages = setImages
        self.maximumDropCount = maximumDropCount
        self.removeImage = removeImage
        self.removeHelp = removeHelp
        self.setImage = setImage
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                Task {
                    guard let selectedImage = await selectImage() else { return }
                    // The picker stores its selected filename on the controller;
                    // nil here means the image well must not invent another one.
                    await setImage((image: selectedImage, filename: nil))
                }
            } label: {
                GeometryReader { proxy in
                    ZStack {
                        if let image = image {
                            Image(image, scale: 1, label: Text(verbatim: ""))
                                .resizable()
                                .scaledToFill()
                                .frame(
                                    width: proxy.size.width * widthModifier,
                                    height: proxy.size.height * heightModifier
                                )
                                .clipped()
                        } else {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                                .background(.background.opacity(0.01))
                                .frame(
                                    width: proxy.size.width * widthModifier,
                                    height: proxy.size.height * heightModifier)
                            // Only show the placeholder icon for reasonable aspect ratios
                            if widthModifier > 1 / 2.5 && heightModifier > 1 / 2.5 {
                                Image(systemName: "photo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(
                                        width: min(
                                            proxy.size.width * widthModifier,
                                            proxy.size.height * heightModifier
                                        ) * 0.45
                                    )
                                    .foregroundColor(Color(nsColor: .separatorColor))
                            }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .buttonStyle(.plain)

            if image != nil {
                removeButton
            }
        }
        .dropDestination(for: ImageDropTransfer.self) { transfers, _ in
            let transfersToLoad =
                maximumDropCount.map { Array(transfers.prefix(max(0, $0))) }
                ?? transfers
            let dropped = transfersToLoad.compactMap(Self.droppedImage(from:))
            guard !dropped.isEmpty else {
                return false
            }

            Task {
                if let setImages {
                    await setImages(dropped)
                } else {
                    guard let first = dropped.first else { return }
                    await self.setImage(first)
                }
            }

            return true
        }
    }

    nonisolated static func droppedImage(
        from transfer: ImageDropTransfer
    ) -> DroppedImage? {
        switch transfer.storage {
        case .imageFile(let data, let filename, let isOriginal):
            guard let image = decodedImage(from: data) else { return nil }
            return (image: image, filename: isOriginal ? filename : nil)

        case .imageData(let data):
            guard let image = decodedImage(from: data) else { return nil }
            return (image: image, filename: nil)
        }
    }

    nonisolated private static func decodedImage(from data: Data) -> CGImage? {
        guard let image = NSImage(data: data) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private var removeButtonLabel: some View {
        Image(systemName: "xmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(.quaternary, lineWidth: 0.5))
    }

    @ViewBuilder
    private var removeButton: some View {
        if let removeImage {
            if let removeHelp {
                Button {
                    Task { await removeImage() }
                } label: {
                    removeButtonLabel
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(removeHelp)
            } else {
                Button {
                    Task { await removeImage() }
                } label: {
                    removeButtonLabel
                }
                .buttonStyle(.plain)
                .padding(4)
            }
        }
    }

}
