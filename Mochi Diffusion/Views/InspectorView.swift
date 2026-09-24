//
//  InspectorView.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/19/22.
//

import CoreML
import SwiftUI

struct InfoGridRow: View {
    var type: LocalizedStringKey
    var text: String?
    var image: CGImage?
    var showCopyToPromptOption: Bool
    var callback: (@MainActor () -> Void)?

    var body: some View {
        GridRow {
            Text("")
            Text(type)
                .helpTextFormat()
        }
        GridRow {
            if showCopyToPromptOption {
                Button {
                    guard let callbackFn = callback else { return }
                    callbackFn()
                } label: {
                    Image(systemName: "arrow.left.circle.fill")
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Copy Option to Sidebar")
            } else {
                Text("")
            }

            VStack(alignment: .leading, spacing: 6) {
                if let text = text {
                    Text(text)
                        .selectableTextFormat()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let image = image {
                    Image(image, scale: 4, label: Text(type))
                        .resizable()
                        .aspectRatio(
                            CGSize(width: image.width, height: image.height), contentMode: .fit
                        )
                        .frame(
                            height: image.height >= image.width
                                ? 90 : 90 * Double(image.height) / Double(image.width))
                }
            }
        }
        Spacer().frame(height: 12)
    }
}

/// The inspector's content is available as soon as an image is selected.
///
/// Full-size pixels are deliberately absent from gallery entries loaded at launch;
/// they are a preview concern, not a prerequisite for showing metadata.
@MainActor
struct InspectorSelection {
    let image: SDImage
    let metadataFields: Set<MetadataField>

    init?(gallery: ImageGallery) {
        guard let image = gallery.selected() else { return nil }
        self.image = image
        self.metadataFields = gallery.metadataFields(for: image.id)
    }
}

private struct InspectorPreviewView: View {
    @Environment(\.galleryFullImageProvider) private var fullImageProvider

    let sdi: SDImage

    @State private var loadedImage: CGImage?
    @State private var loadedImageID: SDImage.ID?

    private var previewImage: CGImage? {
        sdi.image ?? (loadedImageID == sdi.id ? loadedImage : nil)
    }

    var body: some View {
        Group {
            if let image = previewImage {
                Image(image, scale: 1, label: Text(verbatim: String(sdi.prompt)))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .shadow(color: image.averageColor ?? .black, radius: 16)
                    .padding()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding()
            }
        }
        .task(id: sdi.id) {
            loadedImage = nil
            loadedImageID = nil
            guard sdi.image == nil else { return }
            guard let image = await fullImageProvider.image(for: sdi) else { return }
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadedImageID = sdi.id
        }
    }
}

/// A metadata relationship is useful before its pixels arrive, so the filename
/// remains visible while the related gallery image loads. The path owns the task
/// and the result: changing selection to a different relationship cancels the old
/// work, and a late result cannot render for the newer path.
private struct RelatedImageInfoGridRow: View {
    @Environment(\.galleryThumbnailProvider) private var thumbnailProvider
    @Environment(GenerationController.self) private var controller

    let type: LocalizedStringKey
    let filename: String
    let galleryImage: SDImage?
    let allowsReuse: Bool

    @State private var loadedThumbnail: CGImage?
    @State private var loadedPath: String?

    private var image: CGImage? {
        if let residentImage = galleryImage?.image {
            return residentImage
        }
        guard loadedPath == galleryImage?.path else { return nil }
        return loadedThumbnail
    }

    private var canReuse: Bool {
        allowsReuse && galleryImage != nil && controller.galleryImageDestination != nil
    }

    var body: some View {
        InfoGridRow(
            type: type,
            text: filename,
            image: image,
            showCopyToPromptOption: canReuse,
            callback: reuseImage
        )
        .task(id: galleryImage?.path) {
            loadedThumbnail = nil
            loadedPath = nil
            guard let galleryImage, galleryImage.image == nil else { return }
            let path = galleryImage.path
            guard
                let image = await thumbnailProvider.thumbnail(
                    for: path,
                    maxPixelSize: 180
                )
            else { return }
            guard !Task.isCancelled, path == self.galleryImage?.path else { return }
            loadedThumbnail = image
            loadedPath = path
        }
    }

    private func reuseImage() {
        guard canReuse, let galleryImage else { return }
        Task { await controller.useGalleryImage(galleryImage) }
    }
}

struct InspectorView: View {
    @Environment(ImageGallery.self) private var store: ImageGallery
    @Environment(GenerationController.self) private var controller: GenerationController

    var body: some View {
        VStack(spacing: 0) {
            if let selection = InspectorSelection(gallery: store) {
                let sdi = selection.image
                let metadataFields = selection.metadataFields
                let inputImageNames = sdi.inputImages.filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                InspectorPreviewView(sdi: sdi)

                ScrollView(.vertical) {
                    Grid(alignment: .leading, horizontalSpacing: 4) {
                        InfoGridRow(
                            type: LocalizedStringKey(Metadata.date.rawValue),
                            text: sdi.generatedDate.formatted(date: .long, time: .standard),
                            showCopyToPromptOption: false
                        )
                        if metadataFields.contains(.model) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.model.rawValue),
                                text: sdi.model,
                                showCopyToPromptOption: true,
                                callback: controller.copyModelToPrompt
                            )
                        }
                        if metadataFields.contains(.size) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.size.rawValue),
                                text:
                                    "\(sdi.width) x \(sdi.height)",
                                showCopyToPromptOption: true,
                                callback: controller.copySizeToPrompt
                            )
                        }
                        if metadataFields.contains(.quality), !sdi.quality.isEmpty {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.quality.rawValue),
                                text: sdi.quality,
                                showCopyToPromptOption: false
                            )
                        }
                        if metadataFields.contains(.startingImage), !sdi.startingImage.isEmpty {
                            RelatedImageInfoGridRow(
                                type: LocalizedStringKey(Metadata.startingImage.rawValue),
                                filename: sdi.startingImage,
                                galleryImage: store.image(named: sdi.startingImage),
                                allowsReuse: true
                            )
                        }
                        if metadataFields.contains(.controlNetImage), !sdi.controlNetImage.isEmpty {
                            RelatedImageInfoGridRow(
                                type: LocalizedStringKey(Metadata.controlNetImage.rawValue),
                                filename: sdi.controlNetImage,
                                galleryImage: store.image(named: sdi.controlNetImage),
                                allowsReuse: false
                            )
                        }
                        if metadataFields.contains(.inputImages), !inputImageNames.isEmpty {
                            ForEach(
                                Array(inputImageNames.enumerated()),
                                id: \.offset
                            ) { index, name in
                                let label =
                                    inputImageNames.count == 1
                                    ? Metadata.inputImages.rawValue
                                    : "\(Metadata.inputImages.rawValue) \(index + 1)"
                                RelatedImageInfoGridRow(
                                    type: LocalizedStringKey(label),
                                    filename: name,
                                    galleryImage: store.image(named: name),
                                    allowsReuse: true
                                )
                            }
                        }
                        if metadataFields.contains(.loras), !sdi.loras.isEmpty {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.loras.rawValue),
                                text: sdi.loras.map { "\($0.file) (\($0.weight))" }.joined(
                                    separator: "\n"),
                                showCopyToPromptOption: false
                            )
                        }
                        if metadataFields.contains(.prompt) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.includeInImage.rawValue),
                                text: sdi.prompt,
                                showCopyToPromptOption: true,
                                callback: controller.copyPromptToPrompt
                            )
                        }
                        if metadataFields.contains(.negativePrompt) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.excludeFromImage.rawValue),
                                text: sdi.negativePrompt,
                                showCopyToPromptOption: true,
                                callback: controller.copyNegativePromptToPrompt
                            )
                        }
                        if metadataFields.contains(.seed) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.seed.rawValue),
                                text: String(sdi.seed),
                                showCopyToPromptOption: true,
                                callback: controller.copySeedToPrompt
                            )
                        }
                        if metadataFields.contains(.steps) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.steps.rawValue),
                                text: String(sdi.steps),
                                showCopyToPromptOption: true,
                                callback: controller.copyStepsToPrompt
                            )
                        }
                        if metadataFields.contains(.guidanceScale) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.guidanceScale.rawValue),
                                text: String(sdi.guidanceScale),
                                showCopyToPromptOption: true,
                                callback: controller.copyGuidanceScaleToPrompt
                            )
                        }
                        if metadataFields.contains(.scheduler) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.scheduler.rawValue),
                                text: sdi.scheduler.displayName,
                                showCopyToPromptOption: true,
                                callback: controller.copySchedulerToPrompt
                            )
                        }
                        if metadataFields.contains(.mlComputeUnit) {
                            InfoGridRow(
                                type: LocalizedStringKey(Metadata.mlComputeUnit.rawValue),
                                text: MLComputeUnits.toString(sdi.mlComputeUnit),
                                showCopyToPromptOption: false
                            )
                        }
                    }
                }
                .padding([.horizontal])

                Divider()

                HStack {
                    Button {
                        Task { await controller.copyToPrompt() }
                    } label: {
                        Text(
                            "Copy Options to Sidebar",
                            comment:
                                "Button to copy the currently selected image's generation options to the prompt input sidebar"
                        )
                    }
                    Button {
                        let info = sdi.getHumanReadableInfo(including: metadataFields)
                        let pasteboard = NSPasteboard.general
                        pasteboard.declareTypes([.string], owner: nil)
                        pasteboard.setString(info, forType: .string)
                    } label: {
                        Text(
                            "Copy Info",
                            comment:
                                "Button to copy the currently selected image's generation options to the clipboard"
                        )
                    }
                }
                .padding()
            } else {
                Text(
                    "No Info",
                    comment: "Placeholder text for image inspector"
                )
                .font(.title2)
                .foregroundColor(.secondary)
            }
        }
    }
}

extension CGImage {
    /// The image's average color, ignoring alpha.
    ///
    /// Computed from a 40x40 redraw into 8-bit ARGB, which is fast and normalizes
    /// whatever color format the source uses.
    var averageColor: Color? {
        /// First, resize the image. We do this for two reasons,
        /// 1) less pixels to deal with means faster calculation and a resized image still has the "gist" of the colors
        /// 2) the image we're dealing with may come in any of a variety of color formats (CMYK, ARGB, RGBA, etc.) which complicates things, and redrawing it normalizes that into a base color format we can deal with
        /// 40x40 is a good size to resize to still preserve quite a bit of detail but not have too many pixels to deal with. Aspect ratio is irrelevant for just finding average color.
        let size = CGSize(width: 40, height: 40)
        let width = Int(size.width)
        let height = Int(size.height)
        let totalPixels = width * height

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        /// ARGB format
        let bitmapInfo: UInt32 =
            CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        /// 8 bits for each color channel, we're doing ARGB so 32 bits (4 bytes) total, and thus if the image is n pixels wide, and has 4 bytes per pixel, the total bytes per row is 4n.
        /// That gives us 2^8 = 256 color variations for each RGB channel or 256 * 256 * 256 = ~16.7M color options in total.
        /// That seems like a lot, but lots of HDR movies are in 10 bit, which is (2^10)^3 = 1 billion color options!
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        else { return nil }

        /// Draw our resized image
        context.draw(self, in: CGRect(origin: .zero, size: size))

        guard let pixelBuffer = context.data else { return nil }

        /// Bind the pixel buffer's memory location to a pointer we can use/access
        let pointer = pixelBuffer.bindMemory(to: UInt32.self, capacity: width * height)

        /// Keep track of total colors (note: we don't care about alpha and will always assume alpha of 1, AKA opaque)
        var totalRed = 0
        var totalBlue = 0
        var totalGreen = 0

        /// Column of pixels in image
        for x in 0..<width {
            /// Row of pixels in image
            for y in 0..<height {
                /// To get the pixel location just think of the image as a grid of pixels,
                /// but stored as one long row rather than columns and rows,
                /// so for instance to map the pixel from the grid in the 15th row and 3 columns in to our "long row",
                /// we'd offset ourselves 15 times the width in pixels of the image, and then offset by the amount of columns
                let pixel = pointer[(y * width) + x]

                let r = red(for: pixel)
                let g = green(for: pixel)
                let b = blue(for: pixel)

                totalRed += Int(r)
                totalBlue += Int(b)
                totalGreen += Int(g)
            }
        }

        let averageRed = CGFloat(totalRed) / CGFloat(totalPixels)
        let averageGreen = CGFloat(totalGreen) / CGFloat(totalPixels)
        let averageBlue = CGFloat(totalBlue) / CGFloat(totalPixels)

        /// Convert from [0 ... 255] format to Color format [0 ... 1.0]
        return Color(
            red: averageRed / 255.0,
            green: averageGreen / 255.0,
            blue: averageBlue / 255.0,
            opacity: 1.0
        )
    }

    private func red(for pixelData: UInt32) -> UInt8 {
        UInt8((pixelData >> 16) & 255)
    }

    private func green(for pixelData: UInt32) -> UInt8 {
        UInt8((pixelData >> 8) & 255)
    }

    private func blue(for pixelData: UInt32) -> UInt8 {
        UInt8((pixelData >> 0) & 255)
    }
}
