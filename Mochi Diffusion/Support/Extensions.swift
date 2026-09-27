//
//  Extensions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import CompactSlider
import CoreML
import SwiftUI
import UniformTypeIdentifiers

struct MochiCompactSliderStyle: CompactSliderStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color(nsColor: .textColor))
            .background(Color(NSColor.labelColor).opacity(0.075))
            .accentColor(.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension NSApplication {
    nonisolated static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
}

extension CGImage {
    /// Redraws into 8-bit premultiplied sRGB.
    ///
    /// A fallback for encoding: `pngData()` can fail on an image whose colour
    /// space or bit depth the PNG destination will not take — a 16-bit or CMYK
    /// source dragged in from another app. Redrawing costs one copy and makes the
    /// encode succeed rather than dropping the image.
    nonisolated func normalizedRGBA8Image() -> CGImage? {
        let width = self.width
        let height = self.height
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )

        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated func pngData() -> Data? {
        guard
            let data = CFDataCreateMutable(nil, 0),
            let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    nonisolated static func fromData(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return CGImageSourceCreateImageAtIndex(source, index, nil)
    }

    nonisolated func scaledAndCroppedTo(size: CGSize) -> CGImage? {
        let sizeRatio = size.width / size.height
        let imageSizeRatio = Double(self.width) / Double(self.height)
        let scaleFactor =
            sizeRatio > imageSizeRatio
            ? size.width / Double(self.width) : size.height / Double(self.height)
        let scaledWidth = CGFloat(self.width) * scaleFactor
        let scaledHeight = CGFloat(self.height) * scaleFactor

        // Calculate the origin point of the crop
        let cropX = (scaledWidth - size.width) / 2.0
        let cropY = (scaledHeight - size.height) / 2.0

        guard
            let context = CGContext(
                data: nil,
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: self.bitsPerComponent,
                bytesPerRow: 0,
                space: self.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        // Adjust the context to handle the scaled image
        context.translateBy(x: -cropX, y: -cropY)
        context.scaleBy(x: scaleFactor, y: scaleFactor)

        // Draw the image into the context
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Extract the cropped and resized image from the context
        let scaledCroppedImage = context.makeImage()

        return scaledCroppedImage
    }

    func asTransferableImage() -> TransferableImage {
        TransferableImage(image: NSImage(cgImage: self, size: NSSize(width: width, height: height)))
    }
}

struct TransferableImage {
    let image: NSImage
}

extension TransferableImage: Transferable {
    nonisolated public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation<TransferableImage, URL> { transferableImage in
            try transferableImage.image.temporaryFileURL()
        }
    }
}

extension NSImage {
    nonisolated private static let temporaryFilePrefix = "MochiDiffusionTransferImage-"

    nonisolated public static func cleanupTempFiles() {
        let tempDirectory = FileManager.default.temporaryDirectory
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: tempDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        for url in urls where url.lastPathComponent.hasPrefix(Self.temporaryFilePrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Writes the image to a PNG in the temporary directory, named by its content
    /// so the same image reuses one file. Throws if the image has no bitmap
    /// representation that can be encoded.
    nonisolated func temporaryFileURL() throws -> URL {
        guard let tiffData = tiffRepresentation else {
            throw CocoaError(.fileWriteUnknown)
        }
        let filename = "\(Self.temporaryFilePrefix)\(tiffData.hashValue).png"
        let url = FileManager.default.temporaryDirectory.appending(path: filename)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }

        guard
            let pngData = NSBitmapImageRep(data: tiffData)?
                .representation(using: .png, properties: [:])
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileWrapper = FileWrapper(regularFileWithContents: pngData)
        try fileWrapper.write(to: url, originalContentsURL: nil)
        return url
    }
}

extension Text {
    struct SidebarLabelFormat: ViewModifier {
        func body(content: Content) -> some View {
            content
                .textCase(.uppercase)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
    }

    func sidebarLabelFormat() -> some View {
        modifier(SidebarLabelFormat())
    }

    struct HelpTextFormat: ViewModifier {
        func body(content: Content) -> some View {
            content
                .font(.callout)
                .foregroundColor(.secondary)
        }
    }

    func helpTextFormat() -> some View {
        modifier(HelpTextFormat())
    }

    struct SelectableTextFormat: ViewModifier {
        func body(content: Content) -> some View {
            content
                .textSelection(.enabled)
                // Selectable text otherwise renders dark in dark mode.
                .foregroundColor(Color(nsColor: .textColor))
        }
    }

    func selectableTextFormat() -> some View {
        modifier(SelectableTextFormat())
    }
}

extension CompactSliderStyle where Self == MochiCompactSliderStyle {
    static var `mochi`: MochiCompactSliderStyle { MochiCompactSliderStyle() }
}

extension MLComputeUnits {
    nonisolated static func toString(_ computeUnit: MLComputeUnits?) -> String {
        guard let computeUnit = computeUnit else {
            return ""
        }
        switch computeUnit {
        case .cpuOnly:
            return "CPU Only"
        case .cpuAndGPU:
            return "CPU & GPU"
        case .all:
            return "All"
        case .cpuAndNeuralEngine:
            return "CPU & Neural Engine"
        default:
            return ""
        }
    }

    nonisolated static func fromString(_ value: String) -> MLComputeUnits {
        switch value {
        case "CPU Only":
            return .cpuOnly
        case "CPU & GPU":
            return .cpuAndGPU
        case "All":
            return .all
        case "CPU & Neural Engine":
            return .cpuAndNeuralEngine
        default:
            return .all
        }
    }
}

nonisolated extension String {
    /// Trimmed, or `nil` when nothing is left. Filenames arrive from panels and
    /// metadata, and a blank one should read as absent rather than as an empty
    /// name that gets written out.
    var normalizedFilename: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated extension Array {
    /// The element at `index`, or `nil` when it is out of bounds.
    ///
    /// Used where two lists are expected to line up and a mismatch should degrade rather than trap.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
