//
//  MetadataPresenceExportTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Re-encoding an image must preserve the difference between a setting that was
/// recorded, one that was absent, and one that could not be understood.
///
/// `SDImage` carries generation defaults — DPM-Solver++, 28 steps, guidance 11 —
/// which are the right answers for a *new* image and fiction for an imported one.
/// Export paths therefore have to be told which fields the image actually had;
/// `ImageGallery` keeps that set in `metadataFieldsByImageID`.
@MainActor
struct MetadataPresenceExportTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    /// Built through `MetadataCodec.encode` rather than by hand: a caption without
    /// its version header parses under legacy version 1 rules, where these lines are
    /// not separate fields at all. Every fixture also carries a Generator, which
    /// gates import and maps to no `MetadataField`, so it never reaches
    /// `presentFields`.
    private func writePNG(
        _ pairs: [(key: Metadata, value: String)],
        named name: String
    ) throws -> URL {
        let caption = MetadataCodec.encode(pairs + [(.generator, "Mochi Diffusion 6.0")])
        let url = temp.appending(name)
        let data = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        )!
        let properties =
            [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: caption,
                    kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                ]
            ] as CFDictionary
        CGImageDestinationAddImage(destination, makeCGImage(), properties)
        precondition(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
        return url
    }

    /// Exports `sdi` to a new file carrying exactly `fields`, then reads it back the
    /// way the gallery would.
    private func roundTrip(
        _ sdi: SDImage,
        fields: Set<MetadataField>,
        named name: String
    ) async throws -> ImageRecord {
        let data = try #require(await sdi.imageData(.png, metadataFields: fields))
        let url = temp.appending(name)
        try data.write(to: url, options: .atomic)
        return try #require(createImageRecordFromURL(url))
    }

    // MARK: - The export contract

    @Test("Only the recorded fields are written")
    func exportWritesOnlyRecordedFields() async throws {
        var sdi = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        sdi.prompt = "a cat wearing a hat"

        let caption = sdi.metadata(including: [.prompt])

        #expect(caption.contains(Metadata.includeInImage.rawValue))
        #expect(!caption.contains(Metadata.scheduler.rawValue))
        #expect(!caption.contains(Metadata.steps.rawValue))
        #expect(!caption.contains(Metadata.guidanceScale.rawValue))
    }

    @Test("An image with no recorded scheduler does not acquire one on export")
    func absentSchedulerIsNotInvented() async throws {
        let source = try writePNG(
            [(.includeInImage, "a cat wearing a hat")],
            named: "prompt-only.png"
        )
        let imported = try #require(createImageRecordFromURL(source))
        // Precondition: the file really did carry only a prompt.
        #expect(!imported.metadataFields.contains(.scheduler))
        #expect(!imported.metadataFields.contains(.steps))

        let sdi = try #require(createSDImage(from: imported))
        let reimported = try await roundTrip(
            sdi,
            fields: imported.metadataFields,
            named: "exported.png"
        )

        #expect(!reimported.metadataFields.contains(.scheduler))
        #expect(!reimported.metadataFields.contains(.steps))
        #expect(reimported.prompt == "a cat wearing a hat")
    }

    /// `MetadataCodec` drops a scheduler it cannot interpret from `presentFields`.
    /// Export must respect that rather than substituting `SDImage`'s default.
    @Test("An unintelligible scheduler is not replaced by a known one")
    func unknownSchedulerIsNotResolvedToADefault() async throws {
        let source = try writePNG(
            [
                (.includeInImage, "a cat wearing a hat"),
                // Not a Scheduler case, so the codec drops .scheduler from presentFields.
                (.scheduler, "Some Future Sampler"),
            ],
            named: "unknown-scheduler.png"
        )

        let imported = try #require(createImageRecordFromURL(source))
        #expect(!imported.metadataFields.contains(.scheduler))

        let sdi = try #require(createSDImage(from: imported))
        let reimported = try await roundTrip(
            sdi,
            fields: imported.metadataFields,
            named: "unknown-exported.png"
        )

        #expect(!reimported.metadataFields.contains(.scheduler))
    }

    /// Shows why export needs the recorded field set: exporting as though every
    /// field were present publishes `SDImage`'s defaults as fact.
    @Test("Claiming every field is what invents a scheduler")
    func exportingAllFieldsInventsValues() async throws {
        let source = try writePNG(
            [(.includeInImage, "a cat wearing a hat")],
            named: "prompt-only-2.png"
        )
        let imported = try #require(createImageRecordFromURL(source))
        let sdi = try #require(createSDImage(from: imported))

        let reimported = try await roundTrip(
            sdi,
            fields: Set(MetadataField.allCases),
            named: "over-claimed.png"
        )

        #expect(reimported.metadataFields.contains(.scheduler))
        #expect(reimported.scheduler == .dpmSolverMultistepScheduler)
    }

    // MARK: - Where export paths get the set

    @Test("The gallery reports the presence set it was given")
    func galleryRetainsPresencePerImage() {
        let gallery = ImageGallery()
        var sdi = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")
        sdi.prompt = "a cat wearing a hat"

        gallery.add(sdi, metadataFields: [.prompt], animate: false)

        #expect(gallery.metadataFields(for: sdi.id) == [.prompt])
    }

    /// An image the gallery has never seen is assumed fully recorded, which is
    /// correct for a freshly generated image and is the only safe default.
    @Test("An unknown image falls back to every field")
    func unknownImageFallsBackToAllFields() {
        let gallery = ImageGallery()

        #expect(gallery.metadataFields(for: UUID()) == Set(MetadataField.allCases))
    }

    // MARK: - Updating a file in place

    @Test("Updating an image rewrites its file without inventing metadata")
    func updatePreservesRecordedFields() async throws {
        let source = try writePNG(
            [(.includeInImage, "a cat wearing a hat")],
            named: "tagged.png"
        )
        let imported = try #require(createImageRecordFromURL(source))
        let sdi = try #require(createSDImage(from: imported))

        let gallery = ImageGallery()
        gallery.add(sdi, metadataFields: imported.metadataFields, animate: false)

        let originalBytes = try Data(contentsOf: source)
        gallery.update(sdi)

        // update() rewrites the file from an unstructured Task, so wait for the
        // bytes to actually change. Keying on anything the original file already
        // satisfies would pass before the rewrite had happened at all.
        var rewritten = false
        for _ in 0..<100 where !rewritten {
            try await Task.sleep(for: .milliseconds(20))
            rewritten = (try? Data(contentsOf: source)) != originalBytes
        }
        #expect(rewritten, "update() never rewrote the file")

        let result = try #require(createImageRecordFromURL(source))
        #expect(!result.metadataFields.contains(.scheduler))
        #expect(!result.metadataFields.contains(.steps))
        #expect(result.prompt == "a cat wearing a hat")
    }
}
