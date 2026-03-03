//
//  InputImagesView.swift
//  Mochi Diffusion
//

import SwiftUI

struct InputImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        Text(
            "Input Images",
            comment: "Label for setting one or more input reference images"
        )
        .sidebarLabelFormat()

        HStack(alignment: .top) {
            ImageWellView(
                image: controller.currentInputImages.first?.image,
                size: nil,
                selectImage: controller.selectImage
            ) { image in
                if let image {
                    await controller.setInputImage(image: image)
                } else {
                    await controller.unsetInputImage(at: 0)
                }
            }
            .frame(width: 90, height: 90)

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
