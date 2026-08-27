//
//  MetadataCodec.swift
//  Mochi Diffusion
//

import CoreML
import Foundation

/// Owns both directions of the image metadata contract embedded in the IPTC
/// caption: encoding what a generated image records, and decoding what an
/// imported image claims.
///
/// Version 2 separates fields with newlines and escapes the separator inside
/// values, so arbitrary prompts, filenames and future free-text fields survive
/// a round trip. Version 1 — every image written before this type existed —
/// joined fields with `"; "` and escaped nothing, so any value containing that
/// sequence was silently truncated on import. Legacy captions are still read
/// with version 1 rules; they are simply not repairable.
nonisolated enum MetadataCodec {
    /// Bumped only when the encoding rules change, never with the app version.
    /// The app version continues to travel in `Metadata.generator`, which gates
    /// import separately via ``isSupportedGeneratedVersion(_:)``.
    static let currentVersion = 2

    /// Not a `Metadata` case: this is a codec concern, not a field users see.
    /// Version 1 parsing skips it as an unknown key, which is the correct
    /// lenient behaviour.
    static let versionKey = "Metadata Version"

    private static let fieldSeparator = "\n"
    private static let legacyFieldSeparator = "; "
    private static let legacyArraySeparator = ","

    /// A decoded caption. Optional properties distinguish "absent" from
    /// "present but empty"; `presentFields` records which keys were actually
    /// on the image, independently of the values callers fall back to.
    struct Parsed: Sendable {
        var prompt: String?
        var negativePrompt: String?
        var model: String?
        var engine: String?
        var modelKey: String?
        var quality: String?
        var startingImage: String?
        var controlNetImage: String?
        var inputImages: [String] = []
        var scheduler: Scheduler?
        var mlComputeUnit: MLComputeUnits?
        var seed: UInt32?
        var steps: Int?
        var guidanceScale: Double?
        var generatedVersion = ""
        var presentFields: Set<MetadataField> = []
    }

    // MARK: - Encoding

    /// Encodes ordered key/value pairs. Repeat a key to encode a list; callers
    /// never pre-join values, so no value needs a sub-format of its own.
    static func encode(_ pairs: [(key: Metadata, value: String)]) -> String {
        var lines = ["\(versionKey): \(currentVersion)"]
        lines += pairs.map { "\($0.key.rawValue): \(escape($0.value))" }
        return lines.joined(separator: fieldSeparator)
    }

    /// Escapes at the unicode-scalar level, not the character level. `"\r\n"` is
    /// a single Swift `Character` — one extended grapheme cluster — so a
    /// character-by-character switch never matches it against `"\n"` or `"\r"`
    /// and would emit a raw CRLF that then splits the caption apart on import.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }

        var unescaped = ""
        unescaped.unicodeScalars.reserveCapacity(value.unicodeScalars.count)
        var iterator = value.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\\" else {
                unescaped.unicodeScalars.append(scalar)
                continue
            }
            // A trailing lone backslash is malformed; keep it verbatim rather
            // than dropping a character the user typed.
            guard let escaped = iterator.next() else {
                unescaped += "\\"
                break
            }
            switch escaped {
            case "n": unescaped += "\n"
            case "r": unescaped += "\r"
            case "\\": unescaped += "\\"
            // Unknown escape: preserve both scalars so nothing is lost.
            default:
                unescaped += "\\"
                unescaped.unicodeScalars.append(escaped)
            }
        }
        return unescaped
    }

    // MARK: - Decoding

    static func decode(_ caption: String) -> Parsed {
        let version = detectVersion(caption)
        let isLegacy = version < 2
        let fields =
            isLegacy
            ? caption.components(separatedBy: legacyFieldSeparator)
            : caption.components(separatedBy: fieldSeparator)

        var parsed = Parsed()
        for field in fields {
            guard let (key, rawValue) = splitKeyAndValue(field) else { continue }
            let value = isLegacy ? rawValue : unescape(rawValue)
            apply(key: key, value: value, isLegacy: isLegacy, to: &parsed)
        }
        return parsed
    }

    /// Version 2 writes the version first, so detection never has to guess from
    /// the shape of the rest of the caption. That matters because a version 2
    /// value may legitimately contain `"; "`, which version 1 used to separate
    /// fields.
    private static func detectVersion(_ caption: String) -> Int {
        guard
            let firstLine = caption.components(separatedBy: fieldSeparator).first,
            let (key, value) = splitRawKeyAndValue(firstLine),
            key == versionKey,
            let version = Int(value)
        else {
            return 1
        }
        return version
    }

    /// Splits on the first colon without arithmetic that can run past the end
    /// of the field. The previous implementation offset two characters past the
    /// colon and trapped on a recognised key with a bare trailing colon — for
    /// example a caption ending `"…; Model:"` — because the bounds check came
    /// after the offset that violated them.
    private static func splitRawKeyAndValue(_ field: String) -> (key: String, value: String)? {
        guard let separatorIndex = field.firstIndex(of: ":") else { return nil }
        let key = String(field[field.startIndex..<separatorIndex])

        var valueStart = field.index(after: separatorIndex)
        if valueStart < field.endIndex, field[valueStart] == " " {
            valueStart = field.index(after: valueStart)
        }
        return (key, String(field[valueStart...]))
    }

    private static func splitKeyAndValue(_ field: String) -> (key: Metadata, value: String)? {
        guard
            let (rawKey, value) = splitRawKeyAndValue(field),
            let key = Metadata(rawValue: rawKey)
        else {
            return nil
        }
        return (key, value)
    }

    private static func apply(
        key: Metadata,
        value: String,
        isLegacy: Bool,
        to parsed: inout Parsed
    ) {
        if let field = metadataField(for: key) {
            parsed.presentFields.insert(field)
        }

        switch key {
        case .model:
            parsed.model = value
        case .engine:
            parsed.engine = value
        case .modelKey:
            parsed.modelKey = value
        case .includeInImage:
            parsed.prompt = value
        case .excludeFromImage:
            parsed.negativePrompt = value
        case .quality:
            parsed.quality = value
        case .startingImage:
            parsed.startingImage = value
        case .controlNetImage:
            parsed.controlNetImage = value
        case .inputImages:
            // Version 2 repeats the key once per image. Version 1 packed them
            // into one comma-separated value, which could not represent a
            // filename containing a comma.
            if isLegacy {
                parsed.inputImages =
                    value
                    .components(separatedBy: legacyArraySeparator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } else if !value.isEmpty {
                parsed.inputImages.append(value)
            }
        case .seed:
            parsed.seed = UInt32(value)
        case .steps:
            parsed.steps = Int(value)
        case .guidanceScale:
            parsed.guidanceScale = Double(value)
        case .scheduler:
            parsed.scheduler = Scheduler(rawValue: value)
        case .mlComputeUnit:
            parsed.mlComputeUnit = MLComputeUnits.fromString(value)
        case .generator:
            guard let index = value.lastIndex(of: " ") else { break }
            parsed.generatedVersion = String(value[value.index(after: index)...])
        case .date, .size:
            break
        }
    }

    /// Maps a caption key onto the per-model metadata contract. Keys with no
    /// `MetadataField` are codec or display concerns and never appear in a
    /// model's declared field set.
    static func metadataField(for key: Metadata) -> MetadataField? {
        switch key {
        case .includeInImage: return .prompt
        case .excludeFromImage: return .negativePrompt
        case .model: return .model
        case .engine: return .engine
        case .modelKey: return .modelKey
        case .size: return .size
        case .quality: return .quality
        case .startingImage: return .startingImage
        case .controlNetImage: return .controlNetImage
        case .inputImages: return .inputImages
        case .scheduler: return .scheduler
        case .mlComputeUnit: return .mlComputeUnit
        case .seed: return .seed
        case .steps: return .steps
        case .guidanceScale: return .guidanceScale
        case .date, .generator: return nil
        }
    }

    /// Images written by Mochi Diffusion before 2.2 are not imported, because
    /// their captions predate the current field vocabulary.
    static func isSupportedGeneratedVersion(_ generatedVersion: String) -> Bool {
        guard !generatedVersion.isEmpty else { return false }
        return compareVersion("2.2", generatedVersion) != .orderedDescending
    }
}
