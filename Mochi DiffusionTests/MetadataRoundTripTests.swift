//
//  MetadataRoundTripTests.swift
//  Mochi DiffusionTests
//

import AppKit
import CoreML
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Pins the export/import metadata contract: what `SDImage.metadata(including:)`
/// writes must be exactly what `createImageRecordFromURL` reads back, and the
/// declared `metadataFields` must survive the trip as `presentFields`.
///
/// This is the contract every future provider has to satisfy, so these tests
/// exist to fail loudly if the format or the field mapping drifts.
@MainActor
struct MetadataRoundTripTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    /// Values chosen to differ from every default in `createImageRecordFromURL`,
    /// so a dropped field shows up as a mismatch rather than a silent pass.
    static func makeImage() -> SDImage {
        var sdi = SDImage(
            image: makeCGImage(width: 24, height: 16),
            aspectRatio: 1.5,
            path: ""
        )
        sdi.prompt = "a cat wearing a hat"
        sdi.negativePrompt = "blurry, low quality"
        sdi.model = "sd-1.5_512x512"
        sdi.quality = "high"
        sdi.startingImage = "starting.png"
        sdi.controlNetImage = "control.png"
        sdi.inputImages = ["first.png", "second.png"]
        sdi.scheduler = .discreteFlowScheduler
        sdi.mlComputeUnit = .cpuAndNeuralEngine
        sdi.seed = 123_456_789
        sdi.steps = 17
        sdi.guidanceScale = 7.5
        return sdi
    }

    /// Round-trips `sdi` through a real image file on disk and returns the parsed
    /// record.
    func roundTrip(
        _ sdi: SDImage,
        fields: Set<MetadataField>,
        name: String = "image",
        type: UTType = .png
    ) async throws -> ImageRecord? {
        let data = try #require(await sdi.imageData(type, metadataFields: fields))
        let url = temp.appending("\(name).\(type.preferredFilenameExtension!)")
        try data.write(to: url, options: .atomic)
        return createImageRecordFromURL(url)
    }

    /// Version 2 captions separate fields with real newlines, so the whole format
    /// rests on every container preserving embedded LF in the IPTC caption byte
    /// for byte. If one normalised LF to CRLF, every field would decode with a
    /// trailing `\r` and the numeric fields would parse as nil — a silent,
    /// format-wide failure. `SettingsView` offers all three of these types and
    /// only PNG was covered.
    @Test(
        "A multi-line caption survives every image type the app writes",
        arguments: [UTType.png, .jpeg, .heic]
    )
    func captionSurvivesEveryContainer(type: UTType) async throws {
        var sdi = Self.makeImage()
        sdi.prompt = "a cat; wearing a hat\nand a scarf"
        let fields = Set(MetadataField.allCases)

        let record = try #require(
            await roundTrip(sdi, fields: fields, name: "container", type: type)
        )

        #expect(record.prompt == sdi.prompt)
        #expect(record.seed == sdi.seed)
        #expect(record.steps == sdi.steps)
        #expect(record.guidanceScale == sdi.guidanceScale)
        #expect(record.inputImages == sdi.inputImages)
        #expect(record.metadataFields == fields)
    }

    @Test("Every declared field survives an export/import round trip")
    func fullFieldSetRoundTrips() async throws {
        let sdi = Self.makeImage()
        let fields = Set(MetadataField.allCases)

        let record = try #require(await roundTrip(sdi, fields: fields))

        #expect(record.prompt == sdi.prompt)
        #expect(record.negativePrompt == sdi.negativePrompt)
        #expect(record.model == sdi.model)
        #expect(record.quality == sdi.quality)
        #expect(record.startingImage == sdi.startingImage)
        #expect(record.controlNetImage == sdi.controlNetImage)
        #expect(record.inputImages == sdi.inputImages)
        #expect(record.scheduler == sdi.scheduler)
        #expect(record.mlComputeUnit == sdi.mlComputeUnit)
        #expect(record.seed == sdi.seed)
        #expect(record.steps == sdi.steps)
        #expect(record.guidanceScale == sdi.guidanceScale)
        #expect(record.metadataFields == fields)

        // Size is recovered from the pixel buffer, not from the metadata string.
        #expect(record.width == 24)
        #expect(record.height == 16)
    }

    @Test("A restricted field set omits everything it does not declare")
    func restrictedFieldSetOmitsOtherFields() async throws {
        let sdi = Self.makeImage()
        let fields = IrisFluxKleinModel.metadataFields

        let record = try #require(await roundTrip(sdi, fields: fields))

        #expect(record.metadataFields == fields)
        // Declared by the Klein field set.
        #expect(record.prompt == sdi.prompt)
        #expect(record.seed == sdi.seed)
        #expect(record.steps == sdi.steps)
        #expect(record.scheduler == sdi.scheduler)
        #expect(record.inputImages == sdi.inputImages)
        // Not declared, so the importer must fall back to its defaults.
        #expect(record.negativePrompt.isEmpty)
        #expect(record.controlNetImage.isEmpty)
        #expect(record.startingImage.isEmpty)
        #expect(record.mlComputeUnit == nil)
        #expect(record.guidanceScale == 11.0)
    }

    @Test("Declared-but-empty optional values are omitted entirely")
    func emptyOptionalValuesAreOmitted() async throws {
        var sdi = Self.makeImage()
        sdi.quality = ""
        sdi.startingImage = ""
        sdi.controlNetImage = ""
        sdi.inputImages = []

        let record = try #require(
            await roundTrip(sdi, fields: Set(MetadataField.allCases))
        )

        // Requested but empty: the writer drops the key, so import sees it absent.
        #expect(!record.metadataFields.contains(.quality))
        #expect(!record.metadataFields.contains(.startingImage))
        #expect(!record.metadataFields.contains(.controlNetImage))
        #expect(!record.metadataFields.contains(.inputImages))
        // Non-optional keys are still written even when empty.
        #expect(record.metadataFields.contains(.negativePrompt))
    }

    @Test("Multiple input images round trip as one field each")
    func inputImagesRoundTripAsList() async throws {
        var sdi = Self.makeImage()
        sdi.inputImages = ["one.png", "two.png", "three.png"]

        let record = try #require(
            await roundTrip(sdi, fields: [.inputImages])
        )

        #expect(record.inputImages == sdi.inputImages)
    }

    /// Guards the mapping between `MetadataField` and the `Metadata` string keys.
    /// Adding a `MetadataField` without wiring it into both the writer and the
    /// parser fails here rather than silently dropping the field at runtime.
    @Test(
        "Each metadata field is individually writable and parseable",
        arguments: MetadataField.allCases)
    func everyMetadataFieldIsParseable(field: MetadataField) async throws {
        let sdi = Self.makeImage()

        let record = try #require(await roundTrip(sdi, fields: [field], name: field.rawValue))

        #expect(record.metadataFields == [field])
    }

    @Test("Images without a generator version are rejected on import")
    func unversionedMetadataIsRejected() async throws {
        let url = temp.appending("no-version.png")
        try writePNG(caption: "Include in Image: a cat; Model: some-model", to: url)

        #expect(createImageRecordFromURL(url) == nil)
    }

    @Test("Images generated before 2.2 are rejected on import")
    func legacyGeneratorVersionIsRejected() async throws {
        let url = temp.appending("legacy.png")
        try writePNG(
            caption: "Include in Image: a cat; Generator: Mochi Diffusion 2.1",
            to: url
        )

        #expect(createImageRecordFromURL(url) == nil)
    }

    @Test("Unknown metadata keys are skipped without failing the import")
    func unknownKeysAreIgnored() async throws {
        let url = temp.appending("unknown-key.png")
        try writePNG(
            caption:
                "Include in Image: a cat; Provider: Some Future Engine; "
                + "Generator: Mochi Diffusion 6.0",
            to: url
        )

        let record = try #require(createImageRecordFromURL(url))
        #expect(record.prompt == "a cat")
        #expect(record.metadataFields == [.prompt])
    }

    @Test(
        "Prompts containing separators and escapes round trip intact",
        arguments: [
            "a cat; wearing a hat",
            "a cat\nwearing a hat",
            "a cat\r\nwearing a hat",
            "back\\slash",
            "Model: not a key",
            "trailing backslash\\",
        ]
    )
    func hostilePromptRoundTripsThroughAnImage(prompt: String) async throws {
        var sdi = Self.makeImage()
        sdi.prompt = prompt

        let record = try #require(
            await roundTrip(sdi, fields: [.prompt], name: "hostile-\(abs(prompt.hashValue))")
        )

        #expect(record.prompt == prompt)
    }

    /// Multi-line prompts are ordinary — the sidebar prompt field is a
    /// `TextEditor`. They worked by accident under the version 1 format because
    /// newlines were not the separator; under version 2 they only work because
    /// the codec escapes them.
    @Test("A multi-line prompt survives export and import")
    func multiLinePromptRoundTrips() async throws {
        var sdi = Self.makeImage()
        sdi.prompt = "a cat\n\nwearing a hat\nin three lines"

        let record = try #require(await roundTrip(sdi, fields: [.prompt]))

        #expect(record.prompt == sdi.prompt)
    }

    /// Round-trip tests cannot catch a format change, because a compensating
    /// change on both sides still passes. This pins the bytes an image actually
    /// carries, so a codec change that breaks previously-saved images fails
    /// here.
    @Test("The written caption has the expected shape")
    func writtenCaptionShapeIsStable() {
        var sdi = Self.makeImage()
        sdi.prompt = "a cat"
        sdi.inputImages = ["one.png", "two.png"]

        let caption = sdi.metadata(including: [.prompt, .model, .seed, .inputImages])

        #expect(
            caption == """
                Metadata Version: 2
                Include in Image: a cat
                Model: sd-1.5_512x512
                Seed: 123456789
                Input Images: one.png
                Input Images: two.png
                Generator: Mochi Diffusion \(NSApplication.appVersion)
                """
        )
    }
}
