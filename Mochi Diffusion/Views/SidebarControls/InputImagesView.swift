//
//  InputImagesView.swift
//  Mochi Diffusion
//

import SwiftUI

struct InputImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    private let maxWellSide: CGFloat = 90

    private var inputImage: CGImage? {
        controller.currentInputImages.first?.image
    }

    private var imageWellSize: CGSize {
        guard let inputImage else {
            return CGSize(width: maxWellSide, height: maxWellSide)
        }

        let imageWidth = CGFloat(inputImage.width)
        let imageHeight = CGFloat(inputImage.height)
        guard imageWidth > 0, imageHeight > 0 else {
            return CGSize(width: maxWellSide, height: maxWellSide)
        }

        let aspectRatio = imageWidth / imageHeight
        if aspectRatio >= 1 {
            return CGSize(
                width: maxWellSide,
                height: maxWellSide / aspectRatio
            )
        }
        return CGSize(
            width: maxWellSide * aspectRatio,
            height: maxWellSide
        )
    }

    var body: some View {
        Text(
            "Input Images",
            comment: "Label for setting one or more input reference images"
        )
        .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(
                image: inputImage,
                size: nil,
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    await controller.setInputImage(image: image)
                } else {
                    await controller.unsetInputImage(at: 0)
                }
            }
            .frame(width: imageWellSize.width, height: imageWellSize.height)

            Spacer()

            VStack(alignment: .trailing) {
                HStack {
                    Button {
                        Task { await controller.selectInputImage(at: 0) }
                    } label: {
                        Image(systemName: "photo")
                    }

                    Button {
                        Task { await controller.unsetInputImage(at: 0) }
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }
}
