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

/// Save As, Save All and Copy always produce a PNG. A PNG source is copied byte
/// for byte. A JPEG or HEIC source is converted and carries its generation
/// metadata, and only the settings it recorded.
@MainActor
struct ImageExportTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    /// An image in `type` with `properties` written by ImageIO.
    private func writeSource(_ name: String, type: UTType, properties: [CFString: Any] = [:]) throws
        -> URL
    {
        let url = temp.appending(name)
        let data = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(
            data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, makeCGImage(), properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    /// An image with the caption released Mochi Diffusion wrote.
    private func writeReleasedSource(_ name: String, type: UTType, caption: String) throws -> URL {
        try writeSource(
            name, type: type,
            properties: [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: caption,
                    kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                    kCGImagePropertyIPTCProgramVersion: "6.0",
                ]
            ])
    }

    private func type(of url: URL) -> UTType? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let identifier = CGImageSourceGetType(source) as String?
        else { return nil }
        return UTType(identifier)
    }

    private func export(_ source: URL, name: String) async throws -> URL {
        let sdi = SDImage(image: nil, aspectRatio: 1, path: source.path(percentEncoded: false))
        let destination = temp.appending(name)
        try await sdi.writeCopy(to: destination)
        return destination
    }

    @Test("A PNG is copied byte for byte, so its metadata is untouched")
    func pngIsCopiedExactly() async throws {
        let source = temp.appending("source.png")
        try PNGTestChunks.write(
            textChunks: [("parameters", "a cat\nSteps: 8, Seed: 1, Size: 8x8")], to: source)

        let destination = try await export(source, name: "copy.png")

        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
    }

    @Test(
        "A released JPEG or HEIC converts to PNG with only the settings it recorded",
        arguments: [("image.jpg", UTType.jpeg), ("image.heic", UTType.heic)]
    )
    func releasedImageConversion(name: String, sourceType: UTType) async throws {
        let caption = releasedCaption([
            (.includeInImage, "a cat"),
            (.seed, "42"),
            (.scheduler, "Euler"),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let source = try writeReleasedSource(name, type: sourceType, caption: caption)

        let destination = try await export(source, name: "converted.png")
        let converted = try #require(createImageRecordFromURL(destination))

        #expect(type(of: destination) == .png)
        #expect(converted.prompt == "a cat")
        #expect(converted.seed == 42)
        #expect(converted.metadataFields == [.prompt, .seed])
        // A sampler Mochi does not offer stays a shown detail and is not invented
        // as a known scheduler.
        #expect(converted.details.contains(MetadataDetail(label: "Sampler", value: "Euler")))
        #expect(
            converted.details.first
                == MetadataDetail(label: "Generator", value: "Mochi Diffusion 6.0"))
    }

    @Test("Another application's AUTOMATIC1111 text is carried over as it was")
    func foreignTextIsCarried() async throws {
        let text = "a dog\nSteps: 12, Sampler: Euler, CFG scale: 5, Seed: 9, Size: 8x8"
        let source = try writeSource(
            "foreign.jpg", type: .jpeg,
            properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: text]])

        let destination = try await export(source, name: "converted.png")
        let converted = try #require(createImageRecordFromURL(destination))

        #expect(type(of: destination) == .png)
        #expect(converted.prompt == "a dog")
        #expect(converted.steps == 12)
        #expect(
            converted.details.first
                == MetadataDetail(label: "Generator", value: "AUTOMATIC1111-compatible"))
    }

    @Test("An image with no file has nothing to export, and saving it reports a failure")
    func pathlessImageFails() async {
        let sdi = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")

        await #expect(throws: SDImageError.encodingFailed) {
            try await sdi.writeCopy(to: temp.appending("out.png"))
        }
    }

    @Test("A deleted source file reports a failure instead of writing an image without metadata")
    func missingSourceFails() async {
        let sdi = SDImage(
            image: makeCGImage(), aspectRatio: 1,
            path: temp.appending("gone.png").path(percentEncoded: false))

        await #expect(throws: SDImageError.encodingFailed) {
            try await sdi.writeCopy(to: temp.appending("out.png"))
        }
    }

    // MARK: - Presence

    @Test("The gallery reports the presence set it was given")
    func galleryRetainsPresencePerImage() {
        let gallery = ImageGallery()
        let sdi = SDImage(image: nil, aspectRatio: 1, path: "/tmp/a.png")

        gallery.add(sdi, metadataFields: [.prompt, .seed])

        #expect(gallery.metadataFields(for: sdi.id) == [.prompt, .seed])
    }

    @Test("An unknown image falls back to every field")
    func unknownImageFallsBackToAllFields() {
        let gallery = ImageGallery()

        #expect(gallery.metadataFields(for: UUID()) == Set(MetadataField.allCases))
    }
}
