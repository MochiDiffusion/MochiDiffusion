//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import AppKit
import CoreML

nonisolated func compareVersion(_ thisVersion: String, _ compareTo: String) -> ComparisonResult {
    thisVersion.compare(compareTo, options: .numeric)
}

nonisolated func finderTagColorNumberToString(_ tagColorNumber: Int) -> String {
    switch tagColorNumber {
    case 6: return "🎈"
    case 7: return "🔥"
    case 5: return "🍋"
    case 2: return "🍀"
    case 4: return "💎"
    case 3: return "🦄"
    case 1: return "🐘"
    // 0 means file system has no tag
    default: return ""
    }
}

/// Writes a Finder label onto the file. Zero clears every tag.
///
/// Only the filesystem half. Telling the gallery lives on
/// `GalleryController.setFinderTagColorNumber(_:colorNumber:)`, which has the
/// gallery to tell — this used to reach for the singleton from a free function.
nonisolated func writeFinderTagColorNumber(_ path: String, colorNumber: Int) {
    var url = URL(fileURLWithPath: path)
    var rv = URLResourceValues()
    rv.labelNumber = colorNumber
    do {
        try url.setResourceValues(rv)
    } catch {
        print(error.localizedDescription)
    }
}

nonisolated func getFinderTagColorNumber(_ url: URL) -> Int {
    guard let md = MDItemCreateWithURL(nil, url as CFURL) else { return 0 }
    var finderTagColorNumber: Int = 0
    let mdItemFSLabel = MDItemCopyAttribute(md, kMDItemFSLabel)
    if let label = mdItemFSLabel {
        finderTagColorNumber = label as! Int
    }
    return finderTagColorNumber
}

/// Turns a prompt into the human-readable part of an image filename.
///
/// A prompt is content, not a path. In particular, `/` and `..` must not become
/// components interpreted relative to the configured images directory. Keep letters,
/// numbers, spaces, underscores and hyphens; replace everything else with a single
/// space so removing punctuation does not accidentally join words.
nonisolated func sanitizedImageFilenameBase(from prompt: String) -> String? {
    let replacedInvalidCharacters = prompt.replacingOccurrences(
        of: #"[^[:alnum:] _-]+"#,
        with: " ",
        options: .regularExpression
    )
    let collapsedWhitespace = replacedInvalidCharacters.replacingOccurrences(
        of: #"\s+"#,
        with: " ",
        options: .regularExpression
    )
    let trimmed = collapsedWhitespace.trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "._-"))
    )
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(70))
}

/// Builds the filename shared by generation, Save As and Save All.
nonisolated func imageFilenameWithoutExtension(
    prompt: String,
    seed: UInt32,
    count: Int? = nil
) -> String {
    let base = sanitizedImageFilenameBase(from: prompt) ?? "Image"
    if let count {
        return "\(base).\(count).\(seed)"
    }
    return "\(base).\(seed)"
}

/// Decodes a full-size image from a file.
///
/// `CGImageSourceCreateWithURL` rather than reading the bytes first, so ImageIO can
/// map the file instead of the caller holding a second full copy in memory.
nonisolated func cgImageFromFileURL(_ url: URL) -> CGImage? {
    guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
    return CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil)
}

nonisolated func createImageRecordFromURL(_ url: URL) -> ImageRecord? {
    guard
        let attr = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
    else { return nil }
    let maybeDateModified = attr[FileAttributeKey.modificationDate] as? Date

    let finderTagColorNumber = getFinderTagColorNumber(url)

    guard let dateModified = maybeDateModified else { return nil }
    // From the URL, not from bytes read into memory. Only the properties are wanted
    // here, and reading the whole file to get them cost a full copy per gallery
    // image on every load.
    guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(cgImageSource, 0, nil) else {
        return nil
    }
    guard let propDict = properties as? [String: Any] else { return nil }
    guard let iptcProp = propDict[kCGImagePropertyIPTCDictionary as String] as? [String: Any] else {
        return nil
    }
    guard let infoString = iptcProp[kCGImagePropertyIPTCCaptionAbstract as String] as? String
    else { return nil }

    let width = (propDict[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
    let height = (propDict[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0

    var record = ImageRecord(
        id: UUID(),
        prompt: "",
        negativePrompt: "",
        width: width,
        height: height,
        aspectRatio: height > 0 ? Double(width) / Double(height) : 0,
        model: "",
        engine: "",
        modelKey: "",
        quality: "",
        startingImage: "",
        controlNetImage: "",
        inputImages: [],
        scheduler: .dpmSolverMultistepScheduler,
        mlComputeUnit: nil,
        seed: 0,
        steps: 28,
        guidanceScale: 11.0,
        metadataFields: [],
        generatedDate: dateModified,
        path: url.path(percentEncoded: false),
        finderTagColorNumber: finderTagColorNumber,
        // Nil: a gallery image is rendered from a thumbnail read off disk, and the
        // few things needing real pixels ask GalleryFullImageProvider. Only a
        // freshly generated result arrives with its bytes already in hand.
        imageData: nil
    )

    let parsed = MetadataCodec.decode(infoString)
    guard MetadataCodec.isSupportedGeneratedVersion(parsed.generatedVersion) else { return nil }

    record.prompt = parsed.prompt ?? ""
    record.negativePrompt = parsed.negativePrompt ?? ""
    record.model = parsed.model ?? ""
    record.engine = parsed.engine ?? ""
    record.modelKey = parsed.modelKey ?? ""
    record.quality = parsed.quality ?? ""
    record.startingImage = parsed.startingImage ?? ""
    record.controlNetImage = parsed.controlNetImage ?? ""
    record.inputImages = parsed.inputImages
    record.scheduler = parsed.scheduler ?? .dpmSolverMultistepScheduler
    record.mlComputeUnit = parsed.mlComputeUnit
    record.seed = parsed.seed ?? 0
    record.steps = parsed.steps ?? 28
    record.guidanceScale = parsed.guidanceScale ?? 11.0
    record.metadataFields = parsed.presentFields

    return record
}

/// Builds the gallery's model of an image from a record.
///
/// Decodes only when the record carries bytes — a generation result, whose pixels
/// are already in hand. A record loaded from disk leaves `image` nil, and the view
/// asks `GalleryThumbnailProvider` for something the right size instead.
@MainActor
func createSDImage(from record: ImageRecord) -> SDImage? {
    var cgImage: CGImage?
    if let data = record.imageData {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        guard let decoded = CGImageSourceCreateImageAtIndex(source, imageIndex, nil) else {
            return nil
        }
        cgImage = decoded
    }

    // From the record, which read it off the file's properties without decoding.
    let width = record.width > 0 ? record.width : (cgImage?.width ?? 0)
    let height = record.height > 0 ? record.height : (cgImage?.height ?? 0)
    var sdi = SDImage(
        id: record.id,
        image: cgImage,
        aspectRatio: height > 0 ? CGFloat(Double(width) / Double(height)) : 0,
        generatedDate: record.generatedDate,
        path: record.path
    )
    sdi.width = width
    sdi.height = height
    sdi.prompt = record.prompt
    sdi.negativePrompt = record.negativePrompt
    sdi.model = record.model
    sdi.engine = record.engine
    sdi.modelKey = record.modelKey
    sdi.quality = record.quality
    sdi.startingImage = record.startingImage
    sdi.controlNetImage = record.controlNetImage
    sdi.inputImages = record.inputImages
    sdi.scheduler = record.scheduler
    sdi.mlComputeUnit = record.mlComputeUnit
    sdi.seed = record.seed
    sdi.steps = record.steps
    sdi.guidanceScale = record.guidanceScale
    sdi.finderTagColorNumber = record.finderTagColorNumber
    return sdi
}
