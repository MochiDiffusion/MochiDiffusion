//
//  ImageExportTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Save As copies an image rather than converting it. The format is chosen once, in
/// Settings, which is what generation and Save All use; Save As previously inferred a
/// second, invisible choice from the typed extension and could write PNG bytes under
/// a `.jpg` name.
@MainActor
struct ImageExportTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func writeSource(_ name: String, type: UTType, caption: String = "") throws -> URL {
        let url = temp.appending(name)
        let data = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        )!
        let properties =
            [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: caption
                ]
            ] as CFDictionary
        CGImageDestinationAddImage(destination, makeCGImage(), properties)
        precondition(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    private func type(of url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let identifier = CGImageSourceGetType(source) as String?
        else { return nil }
        return UTType(identifier)
    }

    // MARK: - Source type resolution

    @Test(
        "An image reports the type of the file it came from, for both JPEG extensions",
        arguments: [
            ("image.png", UTType.png),
            ("image.jpeg", UTType.jpeg),
            ("image.jpg", UTType.jpeg),
            ("image.JPG", UTType.jpeg),
            ("image.heic", UTType.heic),
        ]
    )
    func contentTypeFollowsTheFile(name: String, expected: UTType) throws {
        var sdi = SDImage()
        sdi.path = temp.appending(name).path(percentEncoded: false)

        #expect(sdi.contentType == expected)
    }

    /// The regression that prompted this change: `.jpg` was unknown to
    /// `UTType.fromString`, whose `default` case returns PNG.
    @Test("A .jpg image is not mistaken for a PNG")
    func jpgIsNotTreatedAsPNG() throws {
        var sdi = SDImage()
        sdi.path = temp.appending("photo.jpg").path(percentEncoded: false)

        #expect(sdi.contentType != .png)
        #expect(sdi.contentType == .jpeg)
    }

    @Test("An image with no file on disk falls back to PNG")
    func pathlessImageFallsBackToPNG() {
        var sdi = SDImage()
        sdi.image = makeCGImage()

        #expect(sdi.sourceURL == nil)
        #expect(sdi.contentType == .png)
    }

    /// The gallery only holds PNG, JPEG and HEIC, so anything else would be a type the
    /// re-encode fallback could not produce.
    @Test("An unsupported extension falls back to PNG rather than offering that type")
    func unsupportedExtensionFallsBackToPNG() {
        var sdi = SDImage()
        sdi.path = temp.appending("scan.tiff").path(percentEncoded: false)

        #expect(sdi.contentType == .png)
    }

    // MARK: - Writing

    @Test(
        "Saving a copy preserves the source type rather than converting it",
        arguments: [
            ("source.jpg", UTType.jpeg),
            ("source.jpeg", UTType.jpeg),
            ("source.heic", UTType.heic),
            ("source.png", UTType.png),
        ]
    )
    func copyKeepsSourceType(name: String, expected: UTType) async throws {
        let source = try writeSource(name, type: expected)
        var sdi = SDImage()
        sdi.path = source.path(percentEncoded: false)

        let destination = temp.appending("exported-\(name)")
        try await sdi.writeCopy(to: destination)

        #expect(type(of: destination) == expected)
    }

    @Test("A disk-backed image is copied byte for byte, so its metadata is untouched")
    func copyIsByteIdentical() async throws {
        let source = try writeSource("meta.png", type: .png, caption: "Include in Image: a cat")
        var sdi = SDImage()
        sdi.path = source.path(percentEncoded: false)
        // Deliberately disagrees with the file: a copy must not publish this.
        sdi.prompt = "something else entirely"

        let destination = temp.appending("copied.png")
        try await sdi.writeCopy(to: destination)

        let copied = try Data(contentsOf: destination)
        let original = try Data(contentsOf: source)
        #expect(copied == original)
    }

    /// Re-encoding remains the fallback for a generated image that has not been written
    /// to the images folder yet, where the resident pixels are the only source.
    @Test("An image with no file is re-encoded from its resident pixels")
    func pathlessImageIsReEncoded() async throws {
        var sdi = SDImage()
        sdi.image = makeCGImage()

        let destination = temp.appending("fresh.png")
        try await sdi.writeCopy(to: destination)

        #expect(type(of: destination) == .png)
    }

    @Test("Saving an image with neither a file nor pixels reports a failure")
    func emptyImageThrows() async {
        let sdi = SDImage()
        let destination = temp.appending("nothing.png")

        await #expect(throws: SDImageError.encodingFailed) {
            try await sdi.writeCopy(to: destination)
        }
    }

    /// A missing or unreadable source file must not lose the image: the resident pixels
    /// are still a valid export.
    @Test("A deleted source file falls back to re-encoding when pixels are resident")
    func missingSourceFallsBackToPixels() async throws {
        var sdi = SDImage()
        sdi.path = temp.appending("gone.png").path(percentEncoded: false)
        sdi.image = makeCGImage()

        let destination = temp.appending("recovered.png")
        try await sdi.writeCopy(to: destination)

        #expect(type(of: destination) == .png)
    }
}
