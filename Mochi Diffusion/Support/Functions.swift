//
//  Functions.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 12/17/2022.
//

import AppKit
import CoreGraphics
import Foundation
import StableDiffusion

func getHumanReadableInfo(sdi: SDImage) -> String {
    """
\(Metadata.date.rawValue):
\(sdi.generatedDate.formatted(date: .long, time: .standard))

\(Metadata.model.rawValue):
\(sdi.model)

\(Metadata.size.rawValue):
\(sdi.width) x \(sdi.height)\(!sdi.upscaler.isEmpty ? " (Upscaled using \(sdi.upscaler))" : "")

\(Metadata.includeInImage.rawValue):
\(sdi.prompt)

\(Metadata.excludeFromImage.rawValue):
\(sdi.negativePrompt)

\(Metadata.scheduler.rawValue):
\(sdi.scheduler.rawValue)

\(Metadata.seed.rawValue):
\(sdi.seed)

\(Metadata.steps.rawValue):
\(sdi.steps)

\(Metadata.guidanceScale.rawValue):
\(sdi.guidanceScale)
"""
}

func createSDImageFromURL(url: URL) -> SDImage? {
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
        width: cgImage.width,
        height: cgImage.height,
        aspectRatio: CGFloat(Double(cgImage.width) / Double(cgImage.height))
    )
    _ = infoString.split(separator: "; ").reduce(into: [String: String]()) {
        let item = $1.split(separator: ": ")

        if let first = item.first, let value = item.last {
            guard let key = Metadata(rawValue: String(first)) else { return }
            switch key {
            case Metadata.model:
                sdi.model = String(value)
            case Metadata.includeInImage:
                sdi.prompt = String(value)
            case Metadata.excludeFromImage:
                sdi.negativePrompt = String(value)
            case Metadata.scheduler:
                sdi.scheduler = StableDiffusionScheduler(rawValue: String(value))!
            case Metadata.seed:
                sdi.seed = UInt32(value)!
            case Metadata.steps:
                sdi.steps = Int(value)!
            case Metadata.guidanceScale:
                sdi.guidanceScale = Double(value)!
            case Metadata.upscaler:
                sdi.upscaler = String(value)
            default:
                break
            }
        }
    }
    return sdi
}
