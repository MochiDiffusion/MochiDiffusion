//
//  ImageWellView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-07.
//

import SwiftUI
import UniformTypeIdentifiers

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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !providers.isEmpty else {
                return false
            }

            Task {
                let dropped = await loadDroppedImages(from: providers)
                guard !dropped.isEmpty else { return }

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

    private func loadDroppedImages(from providers: [NSItemProvider]) async -> [DroppedImage] {
        var droppedImages: [DroppedImage] = []
        let providersToLoad =
            maximumDropCount.map { Array(providers.prefix(max(0, $0))) }
            ?? providers
        droppedImages.reserveCapacity(providersToLoad.count)

        for provider in providersToLoad {
            if let dropped = await loadDroppedImage(from: provider) {
                droppedImages.append(dropped)
            }
        }
        return droppedImages
    }

    func loadDroppedImage(from provider: NSItemProvider) async -> DroppedImage? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            let url = await loadURL(from: provider)
        {
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let imageIndex = CGImageSourceGetPrimaryImageIndex(imageSource)
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, imageIndex, nil) else {
                return nil
            }
            return (image: cgImage, filename: url.lastPathComponent)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
            let data = await loadData(from: provider),
            let image = NSImage(data: data),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            return (image: cgImage, filename: suggestedFilename(from: provider))
        }

        return nil
    }

    /// A suggested name is provenance only when the provider supplied one. Strip
    /// any path components before it reaches metadata; a transfer provider may
    /// expose a path-like string, but Mochi's public contract is a basename.
    private func suggestedFilename(from provider: NSItemProvider) -> String? {
        guard let suggestedName = provider.suggestedName?.normalizedFilename else {
            return nil
        }
        return URL(fileURLWithPath: suggestedName).lastPathComponent.normalizedFilename
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        if let url = await loadFileURLItem(from: provider) {
            return url
        }

        return await loadURLObject(from: provider)
    }

    private func loadFileURLItem(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                continuation.resume(returning: Self.fileURL(from: item))
            }
        }
    }

    private func loadURLObject(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    /// A live SwiftUI drag may serialize an `NSURL` provider into the standard
    /// `public.file-url` data representation. Decode that representation rather
    /// than falling through to anonymous image pixels and losing provenance.
    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        let url: URL?
        switch item {
        case let value as URL:
            url = value
        case let value as Data:
            url = URL(dataRepresentation: value, relativeTo: nil)
        case let value as String:
            url = URL(string: value)
        default:
            url = nil
        }

        guard let url, url.isFileURL else { return nil }
        return url
    }

    private func loadData(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                data,
                _ in
                continuation.resume(returning: data)
            }
        }
    }
}
