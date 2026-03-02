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

nonisolated func getFinderTagColorNumber(_ url: URL) -> Int {
    guard let md = MDItemCreateWithURL(nil, url as CFURL) else { return 0 }
    var finderTagColorNumber: Int = 0
    let mdItemFSLabel = MDItemCopyAttribute(md, kMDItemFSLabel)
    if let label = mdItemFSLabel {
        finderTagColorNumber = label as! Int
    }
    return finderTagColorNumber
}

private struct ParsedMetadataInfo {
    var prompt: String?
    var negativePrompt: String?
    var model: String?
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

nonisolated private func metadataField(for key: Metadata) -> MetadataField? {
    switch key {
    case .includeInImage:
        return .prompt
    case .excludeFromImage:
        return .negativePrompt
    case .model:
        return .model
    case .size:
        return .size
    case .quality:
        return .quality
    case .startingImage:
        return .startingImage
    case .controlNetImage:
        return .controlNetImage
    case .inputImages:
        return .inputImages
    case .scheduler:
        return .scheduler
    case .mlComputeUnit:
        return .mlComputeUnit
    case .seed:
        return .seed
    case .steps:
        return .steps
    case .guidanceScale:
        return .guidanceScale
    case .date, .generator:
        return nil
    }
}

nonisolated private func parseMetadataInfo(_ infoString: String) -> ParsedMetadataInfo {
    var parsed = ParsedMetadataInfo()

    func parseInputImages(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    for field in infoString.split(separator: "; ") {
        guard let separatorIndex = field.firstIndex(of: ":") else { continue }
        guard let key = Metadata(rawValue: String(field[field.startIndex..<separatorIndex])) else {
            continue
        }

        let valueIndex = field.index(separatorIndex, offsetBy: 2)
        guard valueIndex <= field.endIndex else { continue }
        let value = String(field[valueIndex...])

        if let mappedField = metadataField(for: key) {
            parsed.presentFields.insert(mappedField)
        }

        switch key {
        case .model:
            parsed.model = value
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
            parsed.inputImages = parseInputImages(value)
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
            let start = value.index(after: index)
            parsed.generatedVersion = String(value[start...])
        case .date, .size:
            break
        }
    }

    return parsed
}

nonisolated private func isSupportedGeneratedVersion(_ generatedVersion: String) -> Bool {
    guard !generatedVersion.isEmpty else { return false }
    return compareVersion("2.2", generatedVersion) != .orderedDescending
}

nonisolated func createImageRecordFromURL(_ url: URL) -> ImageRecord? {
    guard
        let attr = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
    else { return nil }
    let maybeDateModified = attr[FileAttributeKey.modificationDate] as? Date

    let finderTagColorNumber = getFinderTagColorNumber(url)

    guard let dateModified = maybeDateModified else { return nil }
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let cgImageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
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
        imageData: data
    )

    let parsed = parseMetadataInfo(infoString)
    guard isSupportedGeneratedVersion(parsed.generatedVersion) else { return nil }

    record.prompt = parsed.prompt ?? ""
    record.negativePrompt = parsed.negativePrompt ?? ""
    record.model = parsed.model ?? ""
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

@MainActor
func createSDImage(from record: ImageRecord) -> SDImage? {
    guard let cgImageSource = CGImageSourceCreateWithData(record.imageData as CFData, nil) else {
        return nil
    }
    let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
    guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else {
        return nil
    }

    let aspectRatio = Double(cgImage.width) / Double(cgImage.height)
    var sdi = SDImage(
        id: record.id,
        image: cgImage,
        aspectRatio: CGFloat(aspectRatio),
        generatedDate: record.generatedDate,
        path: record.path
    )
    sdi.prompt = record.prompt
    sdi.negativePrompt = record.negativePrompt
    sdi.model = record.model
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
