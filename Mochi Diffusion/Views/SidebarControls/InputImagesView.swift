//
//  InputImagesView.swift
//  Mochi Diffusion
//

import SwiftUI

struct InputImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    private let columnCount = 3
    private let gridSpacing: CGFloat = 6

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 50, maximum: .infinity), spacing: gridSpacing),
            count: columnCount
        )
    }

    private var visibleWellCount: Int {
        let filledCount = min(controller.currentInputImages.count, controller.maxInputImageCount)
        let progressiveCount = max(1, filledCount + 1)
        return min(progressiveCount, controller.maxInputImageCount)
    }

    private func image(at index: Int) -> CGImage? {
        guard index < controller.currentInputImages.count else { return nil }
        return controller.currentInputImages[index].image
    }

    private func imageAspectRatio(at index: Int) -> CGFloat {
        guard
            let image = image(at: index),
            image.height > 0
        else {
            return 1.0
        }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    var body: some View {
        Text(
            "Input Images",
            comment: "Label for setting one or more input reference images"
        )
        .sidebarLabelFormat()

        LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
            ForEach(0..<visibleWellCount, id: \.self) { index in
                let image = image(at: index)
                ImageWellView(
                    image: image,
                    size: nil,
                    selectImage: controller.selectImage
                ) { image in
                    if let image {
                        await controller.setInputImage(image: image, at: index)
                    } else {
                        await controller.unsetInputImage(at: index)
                    }
                }
                .aspectRatio(imageAspectRatio(at: index), contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if image != nil {
                        Button {
                            Task { await controller.unsetInputImage(at: index) }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.primary)
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.black.opacity(0.35), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            }
        }
    }
}
