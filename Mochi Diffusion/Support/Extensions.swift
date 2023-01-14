//
//  Extensions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import SwiftUI

extension String: Error {}

extension NSApplication {
    static var appVersion: String {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    }
}

extension URL {
    func subDirectories() throws -> [URL] {
        guard hasDirectoryPath else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: self,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter(\.hasDirectoryPath)
    }
}

extension NSImage {
    func getImageHash() -> Int {
        return self.tiffRepresentation!.hashValue
    }
    
    func toPngData() -> Data {
        let imageRepresentation = NSBitmapImageRep(data: self.tiffRepresentation!)
        return (imageRepresentation?.representation(using: .png, properties: [:])!)!
    }
}

extension NSImage: Transferable {
    private static var urlCache = [Int: URL]()

    func temporaryFileURL() throws -> URL {
        let imageHash = self.getImageHash()
        if let cachedURL = NSImage.urlCache[imageHash] {
            return cachedURL
        }
        let name = String(imageHash)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, conformingTo: .png)
        let fileWrapper = FileWrapper(regularFileWithContents: self.toPngData())
        try fileWrapper.write(to: url, originalContentsURL: nil)
        NSImage.urlCache[imageHash] = url
        return url
    }

    public static var transferRepresentation: some TransferRepresentation {
        /// Allow dragging NSImage into Finder as a file.
        ProxyRepresentation<NSImage, URL>(exporting: { image in
            let nsImage: NSImage = image
            return try nsImage.temporaryFileURL()
        })
    }
}

extension CGImage {
    func asNSImage() -> NSImage {
        return NSImage(cgImage: self, size: NSSize(width: width, height: height))
    }
}

extension Formatter {
    static let seedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: UInt32.max) // 4_294_967_295
        formatter.maximumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        formatter.hasThousandSeparators = false
        formatter.alwaysShowsDecimalSeparator = false
        formatter.zeroSymbol = ""
        return formatter
    }()
}
