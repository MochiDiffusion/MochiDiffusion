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
import UniformTypeIdentifiers

func compareVersion(_ thisVersion: String, _ compareTo: String) -> ComparisonResult {
    thisVersion.compare(compareTo, options: .numeric)
}

// swiftlint:disable:next cyclomatic_complexity
func createSDImageFromURL(_ url: URL) -> SDImage? {
    guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else { return nil }
    let maybeDateModified = attr[FileAttributeKey.modificationDate] as? Date
    guard let dateModified = maybeDateModified else { return nil }
    guard let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
    guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil) else { return nil }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(cgImageSource, 0, nil) else { return nil }
    guard let propDict = properties as? [String: Any] else { return nil }
    guard let tiffProp = propDict[kCGImagePropertyTIFFDictionary as String] as? [String: Any] else { return nil }
    guard let infoString = tiffProp[kCGImagePropertyTIFFImageDescription as String] as? String else { return nil }
    var sdi = SDImage(
        id: UUID(),
        image: cgImage,
        aspectRatio: CGFloat(Double(cgImage.width) / Double(cgImage.height)),
        generatedDate: dateModified,
        path: url.path(percentEncoded: false)
    )
    var generatedVersion = ""
    for field in infoString.split(separator: "; ") {
        guard let separatorIndex = field.firstIndex(of: ":") else { continue }
        guard let key = Metadata(rawValue: String(field[field.startIndex..<separatorIndex])) else { continue }
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
            sdi.scheduler = Scheduler(rawValue: String(value)) ?? Scheduler.dpmSolverMultistepKarras
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

    let formattedString = formatter.string(from: TimeInterval((interval / 1_000_000_000) * Double(stepsLeft)))

    return formattedString ?? "-"
}
