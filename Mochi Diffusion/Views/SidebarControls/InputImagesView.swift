//
//  InputImagesView.swift
//  Mochi Diffusion
//

import SwiftUI

struct InputImagesView: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @State private var isBudgetWarningPopoverShown = false

    private let wellHeight: CGFloat = 90

    private var visibleWellCount: Int {
        let filledCount = min(controller.currentInputImages.count, controller.maxInputImageCount)
        let progressiveCount = max(1, filledCount + 1)
        return min(progressiveCount, controller.maxInputImageCount)
    }

    private var budgetReport: IrisReferenceBudgetReport? {
        controller.irisReferenceBudgetReport
    }

    private var shouldShowBudgetWarning: Bool {
        budgetReport?.shouldShowWarning ?? false
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text(
                    "Input Images",
                    comment: "Label for setting one or more input reference images"
                )
                .sidebarLabelFormat()

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(0..<visibleWellCount, id: \.self) { index in
                        InputImageRow(index: index, wellHeight: wellHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if shouldShowBudgetWarning {
                Button {
                    isBudgetWarningPopoverShown.toggle()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isBudgetWarningPopoverShown, arrowEdge: .top) {
                    IrisBudgetWarningPopover(report: budgetReport)
                        .frame(width: 310)
                }
                .padding(.top, 2)
                .zIndex(1)
            }
        }
    }

    private struct IrisBudgetWarningPopover: View {
        let report: IrisReferenceBudgetReport?

        private func format(_ size: CGSize?) -> String {
            guard let size else { return "N/A" }
            return "\(Int(size.width)) x \(Int(size.height))"
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reference Image Budget")
                    .font(.headline)

                if let report {
                    Text("Output: \(format(report.outputSize))")
                    Text("Model heads: \(report.numHeads)")
                    Text(
                        "Remaining ref token budget: \(report.remainingReferenceTokenBudget)"
                    )
                    Text("Per active image budget: \(report.perImageTokenBudget) tokens")
                    Text(
                        """
                        At least one active image is predicted below 256 tokens \
                        (~256x256 equivalent). Reduce output size or use fewer input images \
                        to preserve detail.
                        """
                    )
                    .foregroundStyle(.secondary)
                } else {
                    Text("No active input images.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

private struct InputImageRow: View {
    @Environment(GenerationController.self) private var controller: GenerationController

    let index: Int
    let wellHeight: CGFloat

    @State private var isEditPopoverShown = false

    private var hasImage: Bool {
        index < controller.currentInputImages.count
    }

    private var image: CGImage? {
        guard hasImage else { return nil }
        return controller.editedInputImage(at: index)
    }

    private var editedSize: CGSize? {
        controller.editedInputImageSize(at: index)
    }

    private var predictedSize: CGSize? {
        controller.predictedInputImageSize(at: index)
    }

    private var imageAspectRatio: CGFloat {
        guard
            let image,
            image.height > 0
        else {
            return 1.0
        }
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        return min(max(aspect, 0.75), 1.5)
    }

    private func format(_ size: CGSize?) -> String {
        guard let size else { return "N/A" }
        return "\(Int(size.width)) x \(Int(size.height))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ImageWellView(
                image: image,
                size: nil,
                selectImage: controller.selectImage,
                setImages: { dropped in
                    await controller.setInputImages(dropped, startingAt: index)
                }
            ) { image in
                if let image {
                    await controller.setInputImage(image: image, at: index)
                } else {
                    await controller.unsetInputImage(at: index)
                }
            }
            .aspectRatio(imageAspectRatio, contentMode: .fit)
            .frame(
                minWidth: wellHeight, maxWidth: wellHeight, minHeight: wellHeight,
                maxHeight: wellHeight)

            VStack(alignment: .leading, spacing: 4) {
                if hasImage {
                    HStack(spacing: 8) {
                        Button {
                            isEditPopoverShown.toggle()
                        } label: {
                            Image(systemName: "crop")
                                .frame(minWidth: 18)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isEditPopoverShown, arrowEdge: .trailing) {
                            InputImageEditPopover(index: index)
                                .frame(width: 340)
                        }
                        .help("Crop input image")

                        Button {
                            Task { await controller.unsetInputImage(at: index) }
                        } label: {
                            Image(systemName: "xmark")
                                .frame(minWidth: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Remove input image")
                    }

                    Text("Edited: \(format(editedSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Estimated final: \(format(predictedSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drop or select an image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

private struct InputImageEditPopover: View {
    @Environment(GenerationController.self) private var controller: GenerationController
    @Environment(QuickLookState.self) private var quickLook: QuickLookState
    let index: Int

    private var sourceImage: CGImage? {
        guard index < controller.currentInputImages.count else { return nil }
        return controller.currentInputImages[index].image
    }

    private var edit: IrisReferenceImageEdit {
        controller.inputImageEdit(at: index) ?? .identity
    }

    private func updateEdit(_ mutation: (inout IrisReferenceImageEdit) -> Void) {
        var next = edit
        mutation(&next)
        controller.setInputImageEdit(next, at: index)
    }

    private var normalizedCropRect: CGRect {
        let clamped = edit.clamped()
        let originX = clamped.cropLeftFraction
        let originY = clamped.cropTopFraction
        let width = max(0.05, 1.0 - clamped.cropLeftFraction - clamped.cropRightFraction)
        let height = max(0.05, 1.0 - clamped.cropTopFraction - clamped.cropBottomFraction)
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func updateCropRect(_ normalizedRect: CGRect) {
        let rect = normalizedRect.standardized
        let minX = min(max(rect.minX, 0), 0.95)
        let maxX = max(min(rect.maxX, 1), 0.05)
        let minY = min(max(rect.minY, 0), 0.95)
        let maxY = max(min(rect.maxY, 1), 0.05)

        updateEdit { draft in
            draft.cropLeftFraction = minX
            draft.cropRightFraction = 1.0 - maxX
            draft.cropTopFraction = minY
            draft.cropBottomFraction = 1.0 - maxY
        }
    }

    private func format(_ size: CGSize?) -> String {
        guard let size else { return "N/A" }
        return "\(Int(size.width)) x \(Int(size.height))"
    }

    private var previewImage: CGImage? {
        controller.preprocessedInputImage(at: index)
    }

    private func showQuickLookPreview() {
        guard let previewImage else { return }
        guard
            let previewURL =
                try? previewImage.asTransferableImage().image.temporaryFileURL()
        else {
            return
        }
        quickLook.url = previewURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourceImage {
                Text("Original size: \(sourceImage.width) x \(sourceImage.height)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Cropped size: \(format(controller.editedInputImageSize(at: index)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                CropSelectionView(
                    image: sourceImage,
                    normalizedCropRect: normalizedCropRect,
                    onCropCommit: updateCropRect
                )
                .frame(height: 240)

                Text(
                    "Estimated final size: \(format(controller.predictedInputImageSize(at: index)))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No image selected.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Preview") {
                    showQuickLookPreview()
                }
                Spacer()
                Button("Reset") {
                    controller.resetInputImageEdit(at: index)
                }
            }
        }
        .padding()
    }
}

private struct CropSelectionView: View {
    let image: CGImage
    let normalizedCropRect: CGRect
    let onCropCommit: (CGRect) -> Void

    private let minCropFraction: CGFloat = 0.05
    @State private var dragCropRect: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: image.width, height: image.height)
            let contentRect = aspectFitRect(imageSize: imageSize, in: geometry.size)
            let visibleCropRect = dragCropRect ?? normalizedCropRect
            let cropRect = denormalizedRect(visibleCropRect, in: contentRect)

            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                Path { path in
                    path.addRect(contentRect)
                    path.addRect(cropRect)
                }
                .fill(Color.black.opacity(0.38), style: FillStyle(eoFill: true))

                Rectangle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: cropRect.width, height: cropRect.height)
                    .position(x: cropRect.midX, y: cropRect.midY)

            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dragDelta = hypot(
                            value.location.x - value.startLocation.x,
                            value.location.y - value.startLocation.y
                        )
                        let rect = cropRectFromDrag(
                            start: value.startLocation,
                            end: value.location,
                            contentRect: contentRect,
                            applyMinimum: false
                        )
                        dragCropRect = rect
                        if dragDelta > 1 {
                            onCropCommit(normalized(rect: rect, in: contentRect))
                        }
                    }
                    .onEnded { value in
                        let dragDelta = hypot(
                            value.location.x - value.startLocation.x,
                            value.location.y - value.startLocation.y
                        )
                        guard dragDelta > 1 else {
                            dragCropRect = nil
                            return
                        }

                        let rect = cropRectFromDrag(
                            start: value.startLocation,
                            end: value.location,
                            contentRect: contentRect,
                            applyMinimum: true
                        )
                        dragCropRect = nil
                        onCropCommit(normalized(rect: rect, in: contentRect))
                    }
            )
            .onChange(of: normalizedCropRect) { _, _ in
                dragCropRect = nil
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let scale = min(
            containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (containerSize.width - drawSize.width) / 2,
            y: (containerSize.height - drawSize.height) / 2
        )
        return CGRect(origin: origin, size: drawSize)
    }

    private func denormalizedRect(_ normalizedRect: CGRect, in contentRect: CGRect) -> CGRect {
        CGRect(
            x: contentRect.minX + normalizedRect.minX * contentRect.width,
            y: contentRect.minY + normalizedRect.minY * contentRect.height,
            width: normalizedRect.width * contentRect.width,
            height: normalizedRect.height * contentRect.height
        )
    }

    private func cropRectFromDrag(
        start: CGPoint,
        end: CGPoint,
        contentRect: CGRect,
        applyMinimum: Bool
    ) -> CGRect {
        let startPoint = clamped(point: start, to: contentRect)
        let endPoint = clamped(point: end, to: contentRect)

        let rawMinX = min(startPoint.x, endPoint.x)
        let rawMaxX = max(startPoint.x, endPoint.x)
        let rawMinY = min(startPoint.y, endPoint.y)
        let rawMaxY = max(startPoint.y, endPoint.y)

        let minWidth = applyMinimum ? minCropFraction * contentRect.width : 0
        let minHeight = applyMinimum ? minCropFraction * contentRect.height : 0

        let width = max(rawMaxX - rawMinX, minWidth)
        let height = max(rawMaxY - rawMinY, minHeight)

        let minX = min(max(rawMinX, contentRect.minX), contentRect.maxX - width)
        let minY = min(max(rawMinY, contentRect.minY), contentRect.maxY - height)

        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func clamped(point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func normalized(rect: CGRect, in contentRect: CGRect) -> CGRect {
        guard contentRect.width > 0, contentRect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: (rect.minX - contentRect.minX) / contentRect.width,
            y: (rect.minY - contentRect.minY) / contentRect.height,
            width: rect.width / contentRect.width,
            height: rect.height / contentRect.height
        )
    }
}
