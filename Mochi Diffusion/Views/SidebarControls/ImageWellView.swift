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
    let setImage: @Sendable (CGImage?) async -> Void

    init(
        image: CGImage? = nil,
        size: CGSize?,
        selectImage: @escaping () async -> CGImage?,
        setImages: (@Sendable ([DroppedImage]) async -> Void)? = nil,
        setImage: @escaping @Sendable (CGImage?) async -> Void
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
        self.setImage = setImage
    }

    var body: some View {
        Button {
            Task {
                guard let selectedImage = await selectImage() else { return }
                await setImage(selectedImage)
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
                                .frame(width: 30)
                                .foregroundColor(Color(nsColor: .separatorColor))
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
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
                    await self.setImage(first.image)
                }
            }

            return true
        }
    }

    private func loadDroppedImages(from providers: [NSItemProvider]) async -> [DroppedImage] {
        var droppedImages: [DroppedImage] = []
        droppedImages.reserveCapacity(providers.count)

        for provider in providers {
            if let dropped = await loadDroppedImage(from: provider) {
                droppedImages.append(dropped)
            }
        }
        return droppedImages
    }

    private func loadDroppedImage(from provider: NSItemProvider) async -> DroppedImage? {
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
            return (image: cgImage, filename: nil)
        }

        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
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
