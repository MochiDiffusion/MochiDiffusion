//
//  MetadataCodecTests.swift
//  Mochi DiffusionTests
//

import CoreML
import Foundation
import Testing

@testable import Mochi_Diffusion

/// Unit tests for the caption codec itself, independent of image I/O.
///
/// Version 2 separates fields with newlines and escapes the separator inside
/// values. Version 1 — everything written before this type existed — joined
/// fields with `"; "` and escaped nothing; those captions must keep parsing
/// exactly as they did, since real user galleries are full of them.
struct MetadataCodecTests {

    // MARK: - Round trip

    /// Values that the version 1 format could not represent. Every one of these
    /// must survive `encode` → `decode` byte for byte.
    static let hostileValues: [String] = [
        "a cat; wearing a hat",
        "semi;colon",
        "trailing semicolon;",
        "; leading separator",
        "back\\slash",
        "double\\\\backslash",
        "trailing backslash\\",
        "escape lookalike \\n not a newline",
        "line one\nline two",
        "windows\r\nnewline",
        "just a newline\n",
        "colon: in value",
        "Model: looks like a key",
        "Include in Image: a cat; Generator: Mochi Diffusion 1.0",
        "Metadata Version: 99",
        "",
        " leading space",
        "trailing space ",
        "unicode 🐈 ünïcødé 日本語",
        "everything\\; mixed\n; up: really\\\\",
    ]

    @Test("Hostile prompt values round trip intact", arguments: hostileValues)
    func hostilePromptRoundTrips(value: String) {
        let caption = MetadataCodec.encode([
            (.includeInImage, value),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let parsed = MetadataCodec.decode(caption)

        #expect(parsed.prompt == value)
        #expect(parsed.generatedVersion == "6.0")
        #expect(parsed.presentFields.contains(.prompt))
    }

    @Test("Hostile filenames round trip as individual input images", arguments: hostileValues)
    func hostileInputImageRoundTrips(value: String) {
        let caption = MetadataCodec.encode([
            (.inputImages, value),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let parsed = MetadataCodec.decode(caption)

        // Empty values carry no filename, so nothing is recorded for them.
        #expect(parsed.inputImages == (value.isEmpty ? [] : [value]))
    }

    @Test("A hostile value cannot swallow the fields after it")
    func hostileValueDoesNotConsumeLaterFields() {
        let caption = MetadataCodec.encode([
            (.includeInImage, "a cat\nModel: not-the-real-model; Seed: 1"),
            (.model, "real-model"),
            (.seed, "42"),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let parsed = MetadataCodec.decode(caption)

        #expect(parsed.prompt == "a cat\nModel: not-the-real-model; Seed: 1")
        #expect(parsed.model == "real-model")
        #expect(parsed.seed == 42)
    }

    @Test("Every field survives a full encode/decode cycle")
    func fullFieldSetRoundTrips() {
        let caption = MetadataCodec.encode([
            (.includeInImage, "a cat; wearing a hat"),
            (.excludeFromImage, "blurry\nlow quality"),
            (.model, "sd-1.5_512x512"),
            (.steps, "17"),
            (.guidanceScale, "7.5"),
            (.seed, "123456789"),
            (.size, "24x16"),
            (.quality, "high"),
            (.startingImage, "start; ing.png"),
            (.controlNetImage, "control.png"),
            (.inputImages, "first, one.png"),
            (.inputImages, "second; two.png"),
            (.scheduler, Scheduler.discreteFlowScheduler.rawValue),
            (.mlComputeUnit, MLComputeUnits.toString(.cpuAndNeuralEngine)),
            (.generator, "Mochi Diffusion 6.0"),
        ])
        let parsed = MetadataCodec.decode(caption)

        #expect(parsed.prompt == "a cat; wearing a hat")
        #expect(parsed.negativePrompt == "blurry\nlow quality")
        #expect(parsed.model == "sd-1.5_512x512")
        #expect(parsed.steps == 17)
        #expect(parsed.guidanceScale == 7.5)
        #expect(parsed.seed == 123_456_789)
        #expect(parsed.quality == "high")
        #expect(parsed.startingImage == "start; ing.png")
        #expect(parsed.controlNetImage == "control.png")
        #expect(parsed.inputImages == ["first, one.png", "second; two.png"])
        #expect(parsed.scheduler == .discreteFlowScheduler)
        #expect(parsed.mlComputeUnit == .cpuAndNeuralEngine)
    }

    // MARK: - Encoded shape
    //
    // Round-trip tests alone cannot catch a format change, because a matching
    // change in both directions still passes. These pin the bytes.

    @Test("The encoded caption has the documented shape")
    func encodedShapeIsStable() {
        let caption = MetadataCodec.encode([
            (.includeInImage, "a cat"),
            (.model, "sd15"),
            (.generator, "Mochi Diffusion 6.0"),
        ])

        #expect(
            caption == """
                Metadata Version: 2
                Include in Image: a cat
                Model: sd15
                Generator: Mochi Diffusion 6.0
                """
        )
    }

    @Test("The version marker comes first so detection never guesses")
    func versionMarkerIsFirst() {
        let caption = MetadataCodec.encode([(.includeInImage, "a cat")])

        #expect(caption.hasPrefix("\(MetadataCodec.versionKey): \(MetadataCodec.currentVersion)\n"))
    }

    @Test("Only the separator, the escape character and returns are escaped")
    func escapingIsMinimal() {
        #expect(
            MetadataCodec.escape("plain value: with; punctuation")
                == "plain value: with; punctuation")
        #expect(MetadataCodec.escape("a\nb") == "a\\nb")
        #expect(MetadataCodec.escape("a\r\nb") == "a\\r\\nb")
        #expect(MetadataCodec.escape("a\\b") == "a\\\\b")
    }

    @Test("Unescaping is the exact inverse of escaping", arguments: hostileValues)
    func unescapeInvertsEscape(value: String) {
        #expect(MetadataCodec.unescape(MetadataCodec.escape(value)) == value)
    }

    @Test("An unknown escape sequence is preserved rather than dropped")
    func unknownEscapeIsPreserved() {
        #expect(MetadataCodec.unescape("a\\qb") == "a\\qb")
        #expect(MetadataCodec.unescape("trailing\\") == "trailing\\")
    }

    // MARK: - Malformed input

    /// `parseMetadataInfo` used to offset two characters past the colon and
    /// bounds-check afterwards, so a recognised key with a bare trailing colon
    /// trapped with "String index is out of bounds" instead of parsing. The
    /// caption comes from arbitrary imported files, so this was reachable.
    @Test(
        "A recognised key with no value parses instead of trapping",
        arguments: [
            "Model:",
            "Include in Image: a cat; Model:",
            "Metadata Version: 2\nInclude in Image: a cat\nModel:",
            "Seed:",
            "Metadata Version: 2\nModel:",
            ":",
            "",
            "Metadata Version: 2",
            "Metadata Version:",
            "\n\n\n",
            "; ; ;",
            "Model: a\nModel:",
        ]
    )
    func malformedCaptionsDoNotTrap(caption: String) {
        let parsed = MetadataCodec.decode(caption)

        // Returning at all is the substance of this test. The assertion states
        // the consequence that follows: none of these captions carries a
        // Generator key, so every one of them fails the import gate rather than
        // being half-imported with default values.
        #expect(parsed.generatedVersion.isEmpty)
        #expect(!MetadataCodec.isSupportedGeneratedVersion(parsed.generatedVersion))
    }

    @Test("A key with an empty value is recorded as present but empty")
    func emptyValueIsPresent() {
        let parsed = MetadataCodec.decode("Metadata Version: 2\nModel:")

        #expect(parsed.model == "")
        #expect(parsed.presentFields.contains(.model))
    }

    @Test("Unknown keys are skipped without discarding known ones")
    func unknownKeysAreSkipped() {
        let parsed = MetadataCodec.decode(
            """
            Metadata Version: 2
            Engine: some-future-engine
            Include in Image: a cat
            Revised Prompt: a very fine cat
            Generator: Mochi Diffusion 6.0
            """
        )

        #expect(parsed.prompt == "a cat")
        #expect(parsed.presentFields == [.prompt])
    }

    @Test("A future format version is read with the newest rules we have")
    func futureVersionIsReadLeniently() {
        let parsed = MetadataCodec.decode(
            "Metadata Version: 99\nInclude in Image: a cat\\nwith escapes"
        )

        #expect(parsed.prompt == "a cat\nwith escapes")
    }

    // MARK: - Version 1 compatibility

    @Test("A legacy caption is parsed with legacy rules")
    func legacyCaptionParses() {
        let parsed = MetadataCodec.decode(
            "Include in Image: a cat; Model: sd15; Seed: 7; Steps: 12; "
                + "Generator: Mochi Diffusion 4.2"
        )

        #expect(parsed.prompt == "a cat")
        #expect(parsed.model == "sd15")
        #expect(parsed.seed == 7)
        #expect(parsed.steps == 12)
        #expect(parsed.generatedVersion == "4.2")
    }

    @Test("Legacy values are not unescaped, because nothing escaped them")
    func legacyValuesAreNotUnescaped() {
        let parsed = MetadataCodec.decode(
            "Include in Image: a path\\name and a \\n literal; Generator: Mochi Diffusion 4.2"
        )

        #expect(parsed.prompt == "a path\\name and a \\n literal")
    }

    @Test("Legacy input images keep their comma-separated sub-format")
    func legacyInputImagesParse() {
        let parsed = MetadataCodec.decode(
            "Input Images: one.png, two.png, three.png; Generator: Mochi Diffusion 4.2"
        )

        #expect(parsed.inputImages == ["one.png", "two.png", "three.png"])
    }

    @Test("A legacy caption truncated at a separator still parses what it has")
    func legacyTruncatedCaptionParses() {
        let parsed = MetadataCodec.decode("Include in Image: a cat; Model")

        #expect(parsed.prompt == "a cat")
        #expect(parsed.model == nil)
    }

    // MARK: - Import gate

    @Test(
        "Only images generated by 2.2 or later are importable",
        arguments: [
            ("", false),
            ("2.1", false),
            ("2.2", true),
            ("4.2", true),
            ("6.0", true),
            ("10.0", true),
        ]
    )
    func generatedVersionGate(version: String, supported: Bool) {
        #expect(MetadataCodec.isSupportedGeneratedVersion(version) == supported)
    }
}
