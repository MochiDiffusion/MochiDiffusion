//
//  ImageWellView.swift
//  Mochi Diffusion
//
//  Created by Graham Bing on 2023-11-07.
//

import SwiftUI

struct ImageWellView: View {
    var image: CGImage?
    let setImage: (CGImage?) async -> Void

    var body: some View {
        if let image = image {
            Image(image, scale: 1, label: Text(verbatim: ""))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        } else {
            Button {
                Task { await setImage(ImageController.shared.selectImage()) }
            } label: {
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(Color(nsColor: .separatorColor))
                    .padding(30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .background(.background.opacity(0.01))
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        _ = providers.first?.loadDataRepresentation(for: .fileURL) { data, _ in
                            guard let data, let urlString = String(data: data, encoding: .utf8), let url = URL(string: urlString) else {
                                return
                            }

                            guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                                return
                            }

                            let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)

                            guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else {
                                return
                            }

                            Task { await self.setImage(cgImage) }
                        }

                        return true
                    }
            }
            .buttonStyle(.plain)
        }
    }
}
