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

// zero for clear all tags
func setFinderTagColorNumber(_ sdi: SDImage, colorNumber: Int) {
    var url = URL(fileURLWithPath: sdi.path)
    var rv = URLResourceValues()
    rv.labelNumber = colorNumber
    do {
        try url.setResourceValues(rv)
    } catch {
        print(error.localizedDescription)
    }
    Task { @MainActor in
        ImageGallery.shared.updateMetadata(sdi, colorNumber: colorNumber)
    }
}

func clearFinderTags(_ sdi: SDImage) {
    setFinderTagColorNumber(sdi, colorNumber: 0)
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
        imageData: data
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
