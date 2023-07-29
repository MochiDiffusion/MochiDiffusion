//
//  LocalDiskImageRepo.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/12/23.
//

import AppKit
import CoreML
import Foundation

enum ImageRepoError: Error {
    case couldNotCreateImage
}

struct ImageRepo {

    private let imageDirPath: String?
    private let imageDefaultPath = "MochiDiffusion/images/"
    private let fm = FileManager.default

    var imagesURL: URL {
        if let path = imageDirPath {
            return URL(fileURLWithPath: path, isDirectory: true)
        } else {
            return fm.homeDirectoryForCurrentUser.appending(path: imageDefaultPath, directoryHint: .isDirectory)
        }
    }

    init(imageDirPath: String?) {
        self.imageDirPath = imageDirPath
    }

    func importImage(from url: URL) throws -> SDImage {
        let to = imagesURL.appending(path: url.lastPathComponent)
        try fm.copyItem(at: url, to: to)
        guard let img = try? createSDImageFromURL(url) else {
            throw ImageRepoError.couldNotCreateImage
        }
        return img
    }

    func loadImages() throws -> [SDImage] {

        let urls: [URL] = try fm.contentsOfDirectory(at: imagesURL, includingPropertiesForKeys: nil)
            .filter { $0.isFileURL }
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension) }
        return urls
            .compactMap { try? createSDImageFromURL($0) }
            .sorted { $0.generatedDate < $1.generatedDate }
    }

    func save(image: SDImage) throws {
        fatalError("Not yet implemented")
    }

    func delete(image: SDImage, moveToTrash: Bool) throws {
        let url = URL(fileURLWithPath: image.path, isDirectory: false)
        if moveToTrash {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } else {
            try fm.removeItem(at: url)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func createSDImageFromURL(_ url: URL) throws -> SDImage? {

        guard let dateModified = fm.getDateModified(for: url),
        let cgImageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(cgImageSource)
        guard let cgImage = CGImageSourceCreateImageAtIndex(cgImageSource, imageIndex, nil), let properties = CGImageSourceCopyPropertiesAtIndex(cgImageSource, 0, nil), let propDict = properties as? [String: Any], let tiffProp = propDict[kCGImagePropertyTIFFDictionary as String] as? [String: Any], let infoString = tiffProp[kCGImagePropertyTIFFImageDescription as String] as? String else { return nil }
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
}
