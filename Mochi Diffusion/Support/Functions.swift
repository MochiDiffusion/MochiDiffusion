//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import AppKit
import CoreGraphics
import CoreML
import Foundation
import StableDiffusion
import UniformTypeIdentifiers

func compareVersion(_ thisVersion: String, _ compareTo: String) -> ComparisonResult {
    thisVersion.compare(compareTo, options: .numeric)
}

func finderTagColorNumberToString(_ tagColorNumber: Int) -> String {
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
    ImageStore.shared.updateMetadata(sdi, colorNumber: colorNumber)
}

func clearFinderTags(_ sdi: SDImage) {
    setFinderTagColorNumber(sdi, colorNumber: 0)
}

func getFinderTagColorNumber(_ url: URL) -> Int {
    guard let md = MDItemCreateWithURL(nil, url as CFURL) else { return 0 }
    var finderTagColorNumber: Int = 0
    let mdItemFSLabel = MDItemCopyAttribute(md, kMDItemFSLabel)
    if let label = mdItemFSLabel {
        finderTagColorNumber = label as! Int
    }
    return finderTagColorNumber
}

func createSDImageFromURL(_ url: URL) -> SDImage? {
    guard
        let attr = try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))
    else { return nil }
    let maybeDateModified = attr[FileAttributeKey.modificationDate] as? Date

    let finderTagColorNumber = getFinderTagColorNumber(url)

    guard let dateModified = maybeDateModified else { return nil }
    guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
    guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else {
        return nil
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(cgImageSource, 0, nil) else {
        return nil
    }
    guard let propDict = properties as? [String: Any] else { return nil }
    guard let tiffProp = propDict[kCGImagePropertyTIFFDictionary as String] as? [String: Any] else {
        return nil
    }
    guard let infoString = tiffProp[kCGImagePropertyTIFFImageDescription as String] as? String
    else { return nil }
    var sdi = SDImage(
        id: UUID(),
        image: cgImage,
        aspectRatio: CGFloat(Double(cgImage.width) / Double(cgImage.height)),
        generatedDate: dateModified,
        path: url.path(percentEncoded: false)
    )
    sdi.finderTagColorNumber = finderTagColorNumber
    var generatedVersion = ""
    for field in infoString.split(separator: "; ") {
        guard let separatorIndex = field.firstIndex(of: ":") else { continue }
        guard let key = Metadata(rawValue: String(field[field.startIndex..<separatorIndex])) else {
            continue
        }
        let valueIndex = field.index(separatorIndex, offsetBy: 2)
        let value = String(field[valueIndex...])

        switch key {
        case Metadata.model:
            sdi.model = String(value)
        case Metadata.includeInImage:
            sdi.prompt = String(value)
        case Metadata.excludeFromImage:
            sdi.negativePrompt = String(value)
        case Metadata.seed:
            sdi.seed = UInt32(value)!
        case Metadata.steps:
            sdi.steps = Int(value)!
        case Metadata.guidanceScale:
            sdi.guidanceScale = Double(value)!
        case Metadata.upscaler:
            sdi.upscaler = String(value)
        case Metadata.scheduler:
            sdi.scheduler = Scheduler(rawValue: String(value))!
        case Metadata.mlComputeUnit:
            sdi.mlComputeUnit = MLComputeUnits.fromString(value)
        case Metadata.generator:
            guard let index = value.lastIndex(of: " ") else { break }
            let start = value.index(after: index)
            let end = value.endIndex
            generatedVersion = String(value[start..<end])
        default:
            break
        }
    }
    if generatedVersion.isEmpty { return nil }
    if compareVersion("2.2", generatedVersion) == .orderedDescending { return nil }
    return sdi
}

func formatTimeRemaining(_ interval: Double?, stepsLeft: Int) -> String {
    guard let interval else { return "-" }

    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .short

    let formattedString = formatter.string(
        from: TimeInterval((interval / 1_000_000_000) * Double(stepsLeft)))

    return formattedString ?? "-"
}
