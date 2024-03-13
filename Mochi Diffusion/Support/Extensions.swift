//
//  Extensions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import CompactSlider
import CoreML
import StableDiffusion
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
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    }
}

extension View {
    func syncFocus<T: Equatable>(_ binding: Binding<T>, with focusState: FocusState<T>) -> some View
    {
        self
            .onChange(of: binding.wrappedValue) {
                focusState.wrappedValue = binding.wrappedValue
            }
            .onChange(of: focusState.wrappedValue) {
                binding.wrappedValue = focusState.wrappedValue
            }
    }
}

extension NSImage {
    func getImageHash() -> Int {
        self.tiffRepresentation!.hashValue
    }

    func toPngData() -> Data {
        let imageRepresentation = NSBitmapImageRep(data: self.tiffRepresentation!)
        return (imageRepresentation?.representation(using: .png, properties: [:])!)!
    }
}

extension CGImage {
    func scaledAndCroppedTo(size: CGSize) -> CGImage? {
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
}

public struct TransferableImage {
    public let image: NSImage
}

extension TransferableImage: Transferable {
    public static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation<TransferableImage, URL> { transferableImage in
            try transferableImage.image.temporaryFileURL()
        }
    }
}

extension NSImage {
    private static var urlCache = [Int: URL]()

    public static func cleanupTempFiles() {
        for url in self.urlCache {
            try? FileManager.default.removeItem(at: url.value)
        }
    }

    func temporaryFileURL() throws -> URL {
        let imageHash = self.getImageHash()
        if let cachedURL = Self.urlCache[imageHash],
            FileManager.default.fileExists(atPath: cachedURL.path(percentEncoded: false))
        {
            return cachedURL
        }
        let name = String(imageHash)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            name, conformingTo: .png)
        let fileWrapper = FileWrapper(regularFileWithContents: self.toPngData())
        try fileWrapper.write(to: url, originalContentsURL: nil)
        Self.urlCache[imageHash] = url
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
                .foregroundColor(Color(nsColor: .textColor))
            /// Fixes dark text in dark mode SwiftUI bug
        }
    }

    func selectableTextFormat() -> some View {
        modifier(SelectableTextFormat())
    }
}

extension Binding {
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}

extension CompactSliderStyle where Self == MochiCompactSliderStyle {
    static var `mochi`: MochiCompactSliderStyle { MochiCompactSliderStyle() }
}

extension UTType {
    static func fromString(_ fileExtension: String) -> UTType {
        switch fileExtension {
        case UTType.jpeg.preferredFilenameExtension!:
            return UTType.jpeg
        case UTType.heic.preferredFilenameExtension!:
            return UTType.heic
        default:
            return UTType.png
        }
    }
}

extension MLComputeUnits {
    static func toString(_ computeUnit: MLComputeUnits?) -> String {
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

    static func fromString(_ value: String) -> MLComputeUnits {
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
