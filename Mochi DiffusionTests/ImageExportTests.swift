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

/// Save As always writes a PNG. A PNG source is copied byte for byte; a JPEG or HEIC
/// source is converted, carrying only the metadata fields it recorded.
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
        "Saving a copy always produces a PNG",
        arguments: [
            ("source.jpg", UTType.jpeg),
            ("source.jpeg", UTType.jpeg),
            ("source.heic", UTType.heic),
            ("source.png", UTType.png),
        ]
    )
    func copyIsAlwaysPNG(name: String, sourceType: UTType) async throws {
        let source = try writeSource(name, type: sourceType)
        var sdi = SDImage()
        sdi.path = source.path(percentEncoded: false)

        let destination = temp.appending("exported-\(name).png")
        try await sdi.writeCopy(to: destination, metadataFields: [])

        #expect(type(of: destination) == .png)
    }

    @Test(
        "Converting to PNG keeps the recorded metadata and adds nothing",
        arguments: [("source.jpg", UTType.jpeg), ("source.heic", UTType.heic)]
    )
    func conversionKeepsOnlyRecordedFields(name: String, sourceType: UTType) async throws {
        let caption = MetadataCodec.encode([
            (.includeInImage, "a cat"), (.generator, "Mochi Diffusion 6.0"),
        ])
        let source = try writeSource(name, type: sourceType, caption: caption)
        let record = try #require(createImageRecordFromURL(source))
        let sdi = try #require(createSDImage(from: record))

        let destination = temp.appending("converted.png")
        try await sdi.writeCopy(to: destination, metadataFields: record.metadataFields)

        let converted = try #require(createImageRecordFromURL(destination))
        #expect(converted.prompt == "a cat")
        #expect(!converted.metadataFields.contains(.steps))
        #expect(!converted.metadataFields.contains(.scheduler))
    }

    @Test("A disk-backed image is copied byte for byte, so its metadata is untouched")
    func copyIsByteIdentical() async throws {
        let source = try writeSource("meta.png", type: .png, caption: "Include in Image: a cat")
        var sdi = SDImage()
        sdi.path = source.path(percentEncoded: false)
        // Deliberately disagrees with the file: a copy must not publish this.
        sdi.prompt = "something else entirely"

        let destination = temp.appending("copied.png")
        try await sdi.writeCopy(to: destination, metadataFields: Set(MetadataField.allCases))

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
        try await sdi.writeCopy(to: destination, metadataFields: Set(MetadataField.allCases))

        #expect(type(of: destination) == .png)
    }

    @Test("Saving an image with neither a file nor pixels reports a failure")
    func emptyImageThrows() async {
        let sdi = SDImage()
        let destination = temp.appending("nothing.png")

        await #expect(throws: SDImageError.encodingFailed) {
            try await sdi.writeCopy(to: destination, metadataFields: Set(MetadataField.allCases))
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
        try await sdi.writeCopy(to: destination, metadataFields: Set(MetadataField.allCases))

        #expect(type(of: destination) == .png)
    }
}
