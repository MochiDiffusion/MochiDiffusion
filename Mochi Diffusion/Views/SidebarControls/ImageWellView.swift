//
//  ImageWellView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-07.
//

import SwiftUI

struct ImageWellView: View {
    var image: CGImage?
    let widthModifier: Double
    let heightModifier: Double
    let setImage: (CGImage?) async -> Void

    init(image: CGImage? = nil, size: CGSize?, setImage: @escaping (CGImage?) async -> Void) {
        self.image = image
        if let width = size?.width, let height = size?.height {
            let aspectRatio = width / height
            self.widthModifier = aspectRatio < 1.0 ? aspectRatio : 1.0
            self.heightModifier = aspectRatio > 1.0 ? 1 / aspectRatio : 1.0
        } else {
            self.widthModifier = 1.0
            self.heightModifier = 1.0
        }
        self.setImage = setImage
    }

    var body: some View {
        Button {
            Task { await setImage(ImageController.shared.selectImage()) }
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
                        Image(systemName: "photo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 30)
                            .foregroundColor(Color(nsColor: .separatorColor))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadDataRepresentation(for: .fileURL) { data, _ in
                guard let data, let urlString = String(data: data, encoding: .utf8),
                    let url = URL(string: urlString)
                else {
                    return
                }

                guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    return
                }

                let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)

                guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil)
                else {
                    return
                }

                Task { await self.setImage(cgImage) }
            }

            return true
        }
    }
}
