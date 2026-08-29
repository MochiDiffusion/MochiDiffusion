//
//  IrisReferenceImageSupport.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation

nonisolated struct IrisReferenceImageEdit: Sendable, Equatable {
    var cropLeftFraction: Double = 0
    var cropRightFraction: Double = 0
    var cropTopFraction: Double = 0
    var cropBottomFraction: Double = 0

    static let identity = IrisReferenceImageEdit()

    func clamped() -> IrisReferenceImageEdit {
        var copy = self
        copy.cropLeftFraction = min(max(copy.cropLeftFraction, 0), 0.95)
        copy.cropRightFraction = min(max(copy.cropRightFraction, 0), 0.95)
        copy.cropTopFraction = min(max(copy.cropTopFraction, 0), 0.95)
        copy.cropBottomFraction = min(max(copy.cropBottomFraction, 0), 0.95)

        let maxCombinedCrop = 0.95
        let horizontalTotal = copy.cropLeftFraction + copy.cropRightFraction
        if horizontalTotal > maxCombinedCrop, horizontalTotal > 0 {
            let scale = maxCombinedCrop / horizontalTotal
            copy.cropLeftFraction *= scale
            copy.cropRightFraction *= scale
        }

        let verticalTotal = copy.cropTopFraction + copy.cropBottomFraction
        if verticalTotal > maxCombinedCrop, verticalTotal > 0 {
            let scale = maxCombinedCrop / verticalTotal
            copy.cropTopFraction *= scale
            copy.cropBottomFraction *= scale
        }

        return copy
    }
}

nonisolated enum IrisReferenceImageProcessor {
    static func editedPixelSize(
        for image: CGImage,
        edit: IrisReferenceImageEdit
    ) -> CGSize {
        let clampedEdit = edit.clamped()
        let croppedRect = cropRect(for: image, edit: clampedEdit)

        return CGSize(
            width: max(1, Int(croppedRect.width)),
            height: max(1, Int(croppedRect.height))
        )
    }

    static func applyEdits(
        to image: CGImage,
        edit: IrisReferenceImageEdit
    ) -> CGImage? {
        let clampedEdit = edit.clamped()
        let croppedRect = cropRect(for: image, edit: clampedEdit)
        return image.cropping(to: croppedRect)
    }

    /// Resizes with aspect-fill and center-crops to a 16px-token-aligned target size.
    /// This avoids geometric distortion from direct width/height stretching.
    static func resizedAndCroppedToTokenGrid(_ image: CGImage, to targetSize: CGSize) -> CGImage? {
        let normalizedTarget = IrisReferenceBudgetEstimator.normalizedPixelSize(targetSize)
        let targetWidth = Int(normalizedTarget.width)
        let targetHeight = Int(normalizedTarget.height)
        guard targetWidth > 0, targetHeight > 0 else { return nil }
        if image.width == targetWidth, image.height == targetHeight {
            return image
        }

        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let destinationWidth = CGFloat(targetWidth)
        let destinationHeight = CGFloat(targetHeight)
        let scale = max(destinationWidth / sourceWidth, destinationHeight / sourceHeight)
        let drawWidth = sourceWidth * scale
        let drawHeight = sourceHeight * scale
        let drawRect = CGRect(
            x: (destinationWidth - drawWidth) / 2,
            y: (destinationHeight - drawHeight) / 2,
            width: drawWidth,
            height: drawHeight
        )

        guard let context = makeRGBA8Context(width: targetWidth, height: targetHeight) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    private static func cropRect(
        for image: CGImage,
        edit: IrisReferenceImageEdit
    ) -> CGRect {
        let clampedEdit = edit.clamped()
        let width = Double(image.width)
        let height = Double(image.height)

        let x = width * clampedEdit.cropLeftFraction
        let y = height * clampedEdit.cropTopFraction
        let croppedWidth =
            width * (1 - clampedEdit.cropLeftFraction - clampedEdit.cropRightFraction)
        let croppedHeight =
            height * (1 - clampedEdit.cropTopFraction - clampedEdit.cropBottomFraction)

        let rect = CGRect(
            x: x.rounded(.towardZero),
            y: y.rounded(.towardZero),
            width: max(1, croppedWidth.rounded(.towardZero)),
            height: max(1, croppedHeight.rounded(.towardZero))
        )
        return rect.integral
    }

    private static func makeRGBA8Context(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )

        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
    }
}

nonisolated struct IrisReferenceBudgetReport: Sendable {
    let numHeads: Int
    let outputSize: CGSize
    let outputTokenCount: Int
    let textTokenCount: Int
    let maxTotalTokenCount: Int
    let remainingReferenceTokenBudget: Int
    let perImageTokenBudget: Int
    let normalizedReferenceSizes: [CGSize]
    let predictedReferenceSizes: [CGSize]
    let predictedReferenceTokenCounts: [Int]

    static let warningTokenThreshold = 256

    var shouldShowWarning: Bool {
        guard !predictedReferenceTokenCounts.isEmpty else { return false }
        if perImageTokenBudget < Self.warningTokenThreshold {
            return true
        }
        return predictedReferenceTokenCounts.contains { $0 < Self.warningTokenThreshold }
    }
}

nonisolated enum IrisReferenceBudgetEstimator {
    static let maxImageDimension = 1792
    static let patchSize = 16
    static let fluxTextTokenCount = 512
    static let maxAttentionBytes = 4 * 1024 * 1024 * 1024

    static func estimate(
        numHeads: Int,
        outputSize: CGSize,
        referenceSizes: [CGSize]
    ) -> IrisReferenceBudgetReport {
        let safeNumHeads = max(1, numHeads)
        let outputPixelSize = normalizedPixelSize(outputSize)
        let outputTokenCount = tokenCount(for: outputPixelSize)
        let textTokenCount = fluxTextTokenCount
        let maxTotalTokenCount = maxSequenceTokenCount(numHeads: safeNumHeads)
        let totalWithoutRefs = outputTokenCount + textTokenCount
        let remainingReferenceTokenBudget = max(0, maxTotalTokenCount - totalWithoutRefs)
        let activeImageCount = max(1, referenceSizes.count)
        let perImageTokenBudget = remainingReferenceTokenBudget / activeImageCount

        let normalizedReferences = referenceSizes.map(normalizedPixelSize(_:))
        var predictedReferences = normalizedReferences
        fitReferencesForAttention(
            numHeads: safeNumHeads,
            outputTokenCount: outputTokenCount,
            textTokenCount: textTokenCount,
            refSizes: &predictedReferences
        )

        return IrisReferenceBudgetReport(
            numHeads: safeNumHeads,
            outputSize: outputPixelSize,
            outputTokenCount: outputTokenCount,
            textTokenCount: textTokenCount,
            maxTotalTokenCount: maxTotalTokenCount,
            remainingReferenceTokenBudget: remainingReferenceTokenBudget,
            perImageTokenBudget: perImageTokenBudget,
            normalizedReferenceSizes: normalizedReferences,
            predictedReferenceSizes: predictedReferences,
            predictedReferenceTokenCounts: predictedReferences.map(tokenCount(for:))
        )
    }

    private static func fitReferencesForAttention(
        numHeads: Int,
        outputTokenCount: Int,
        textTokenCount: Int,
        refSizes: inout [CGSize]
    ) {
        guard !refSizes.isEmpty else { return }
        guard
            attentionBytes(
                numHeads: numHeads,
                outputTokenCount: outputTokenCount,
                textTokenCount: textTokenCount,
                refSizes: refSizes
            ) > maxAttentionBytes
        else {
            return
        }

        while true {
            var bestIndex: Int?
            var bestTokens = 0
            for (index, size) in refSizes.enumerated() {
                let tokens = tokenCount(for: size)
                if tokens > bestTokens {
                    bestTokens = tokens
                    bestIndex = index
                }
            }

            guard let bestIndex else { break }
            guard bestTokens > 1 else { break }

            let current = refSizes[bestIndex]
            let resized = normalizedPixelSize(
                CGSize(
                    width: max(16, (current.width * 0.9).rounded(.towardZero)),
                    height: max(16, (current.height * 0.9).rounded(.towardZero))
                )
            )

            if resized == current { break }
            refSizes[bestIndex] = resized

            if attentionBytes(
                numHeads: numHeads,
                outputTokenCount: outputTokenCount,
                textTokenCount: textTokenCount,
                refSizes: refSizes
            ) <= maxAttentionBytes {
                break
            }
        }
    }

    private static func attentionBytes(
        numHeads: Int,
        outputTokenCount: Int,
        textTokenCount: Int,
        refSizes: [CGSize]
    ) -> Int {
        let refTokens = refSizes.map(tokenCount(for:)).reduce(0, +)
        let totalTokens = outputTokenCount + textTokenCount + refTokens
        return numHeads * totalTokens * totalTokens * MemoryLayout<Float>.size
    }

    private static func maxSequenceTokenCount(numHeads: Int) -> Int {
        let denominator = Double(numHeads * MemoryLayout<Float>.size)
        let ratio = Double(maxAttentionBytes) / denominator
        return Int(floor(sqrt(ratio)))
    }

    static func normalizedPixelSize(_ size: CGSize) -> CGSize {
        let normalizedWidth = normalizedDimension(Int(size.width.rounded(.towardZero)))
        let normalizedHeight = normalizedDimension(Int(size.height.rounded(.towardZero)))
        return CGSize(width: normalizedWidth, height: normalizedHeight)
    }

    static func tokenCount(for size: CGSize) -> Int {
        let width = normalizedDimension(Int(size.width.rounded(.towardZero)))
        let height = normalizedDimension(Int(size.height.rounded(.towardZero)))
        return (width / patchSize) * (height / patchSize)
    }

    private static func normalizedDimension(_ value: Int) -> Int {
        let clamped = min(max(value, patchSize), maxImageDimension)
        return max(patchSize, (clamped / patchSize) * patchSize)
    }
}
