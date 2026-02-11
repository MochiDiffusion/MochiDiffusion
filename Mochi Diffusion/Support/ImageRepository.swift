//
//  ImageRepository.swift
//  Mochi Diffusion
//

import CoreML
import Foundation
import UniformTypeIdentifiers

struct ImageRecord: Sendable, Identifiable {
    let id: UUID
    var prompt: String
    var negativePrompt: String
    var width: Int
    var height: Int
    var aspectRatio: Double
    var model: String
    var scheduler: Scheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32
    var steps: Int
    var guidanceScale: Double
    var metadataFields: Set<MetadataField>
    var generatedDate: Date
    var path: String
    var finderTagColorNumber: Int
    var imageData: Data
}

struct ImageExportRequest: Sendable {
    let filenameWithoutExtension: String
    let imageData: Data
}

struct ImageSyncResult: Sendable {
    let additions: [ImageRecord]
    let removals: [String]
}

enum ImageRepositoryError: Error {
    case imageDirectoryNoAccess(String)
}

actor ImageRepository {
    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    nonisolated static func imageDirectoryURL(fromPath directory: String) -> URL {
        FileSystemStore().directoryURL(
            fromPath: directory,
            defaultingTo: "MochiDiffusion/images"
        )
    }

    func load(imageDir: String) async throws -> [ImageRecord] {
        let directoryURL = Self.imageDirectoryURL(fromPath: imageDir)
        do {
            try fileSystem.ensureDirectoryExists(directoryURL)
        } catch {
            throw ImageRepositoryError.imageDirectoryNoAccess(
                directoryURL.path(percentEncoded: false)
            )
        }

        let items = try fileSystem.contentsOfDirectory(at: directoryURL)
        let imageURLs =
            items
            .filter { $0.isFileURL }
            .filter { ["png", "jpg", "jpeg", "heic"].contains($0.pathExtension) }

        var records: [ImageRecord] = []
        for url in imageURLs {
            guard let record = createImageRecordFromURL(url) else { continue }
            records.append(record)
        }
        records.sort { $0.generatedDate < $1.generatedDate }
        return records
    }

    func importImages(from urls: [URL], imageDir: String) async -> ([ImageRecord], Int) {
        var records: [ImageRecord] = []
        var failed = 0

        for url in urls {
            var importedURL = URL(fileURLWithPath: imageDir, isDirectory: true)
            importedURL.append(path: url.lastPathComponent)
            do {
                try fileSystem.copyItem(at: url, to: importedURL)
            } catch {
                failed += 1
                continue
            }
            guard let record = createImageRecordFromURL(importedURL) else {
                failed += 1
                continue
            }
            records.append(record)
        }

        return (records, failed)
    }

    func delete(path: String, moveToTrash: Bool) async {
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path, isDirectory: false)
        if moveToTrash {
            try? fileSystem.trashItem(at: url)
        } else {
            try? fileSystem.removeItem(at: url)
        }
    }

    func saveUpdatedImage(path: String, data: Data) async -> URL? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        let pathWithoutExtension = url.deletingPathExtension()
        let type = UTType.fromString(url.pathExtension.lowercased())
        return saveImageData(data, pathWithoutExtension: pathWithoutExtension, type: type)
    }

    func writeImage(
        filenameWithoutExtension: String,
        imageData: Data,
        imageDir: String,
        imageType: String,
    ) async -> URL? {
        var pathURL = URL(fileURLWithPath: imageDir, isDirectory: true)
        pathURL.append(path: filenameWithoutExtension)

        let type = UTType.fromString(imageType)
        return saveImageData(imageData, pathWithoutExtension: pathURL, type: type)
    }

    func ensureOutputDirectory(imageDir: String) throws -> URL {
        let directoryURL = Self.imageDirectoryURL(fromPath: imageDir)
        do {
            try fileSystem.ensureDirectoryExists(directoryURL)
        } catch {
            throw ImageRepositoryError.imageDirectoryNoAccess(
                directoryURL.path(percentEncoded: false)
            )
        }

        guard fileSystem.isWritableDirectory(directoryURL) else {
            throw ImageRepositoryError.imageDirectoryNoAccess(
                directoryURL.path(percentEncoded: false)
            )
        }

        return directoryURL
    }

    func exportAllImages(_ images: [ImageExportRequest], to directory: URL, type: UTType) async {
        for request in images {
            let url = directory.appending(path: request.filenameWithoutExtension)
            _ = saveImageData(request.imageData, pathWithoutExtension: url, type: type)
        }
    }

    func syncImages(imageDir: String, existingPaths: [String]) async -> ImageSyncResult {
        let directoryURL = URL(fileURLWithPath: imageDir, isDirectory: true)
        guard
            let fileList = try? fileSystem.contentsOfDirectory(at: directoryURL).map({
                $0.lastPathComponent
            })
        else {
            return ImageSyncResult(additions: [], removals: [])
        }

        let existingSet = Set(existingPaths)
        var additions: [ImageRecord] = []
        var removals: [String] = []

        for filePath in fileList {
            if !existingSet.contains(where: { URL(filePath: $0).lastPathComponent == filePath }) {
                let fileURL = URL(filePath: imageDir).appending(component: filePath)
                if let record = createImageRecordFromURL(fileURL) {
                    additions.append(record)
                }
            }
        }

        for path in existingPaths {
            if !fileList.contains(where: { $0 == URL(filePath: path).lastPathComponent }) {
                removals.append(path)
            }
        }

        return ImageSyncResult(additions: additions, removals: removals)
    }

    private func saveImageData(
        _ data: Data,
        pathWithoutExtension: URL,
        type: UTType
    ) -> URL? {
        let url = pathWithoutExtension.appendingPathExtension(for: type)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("*** Error saving image file: \(error.localizedDescription)")
            return nil
        }
        return url
    }
}
