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
    var engine: String
    var modelKey: String
    var quality: String
    var startingImage: String
    var controlNetImage: String
    var inputImages: [String]
    var scheduler: Scheduler
    var mlComputeUnit: MLComputeUnits?
    var seed: UInt32
    var steps: Int
    var guidanceScale: Double
    var metadataFields: Set<MetadataField>
    var generatedDate: Date
    var path: String
    var finderTagColorNumber: Int
    /// The encoded image, when the caller already has it.
    ///
    /// Set for a generation result, whose bytes were just written to disk anyway, so
    /// the gallery can show it without a read-back. Nil for a record built by
    /// scanning the images folder; the grid renders those from
    /// `GalleryThumbnailProvider`.
    var imageData: Data?
    var loras: [LoRASelection] = []
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
    private static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic"]

    private let fileSystem: FileSystemStore
    private let defaultImageDirectoryURL: URL

    init(
        fileSystem: FileSystemStore = FileSystemStore(),
        defaultImageDirectoryURL: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.defaultImageDirectoryURL =
            defaultImageDirectoryURL ?? Self.imageDirectoryURL(fromPath: "")
    }

    nonisolated static func imageDirectoryURL(fromPath directory: String) -> URL {
        FileSystemStore().directoryURL(
            fromPath: directory,
            defaultingTo: "MochiDiffusion/images"
        )
    }

    func load(imageDir: String) throws -> [ImageRecord] {
        let directoryURL = resolvedImageDirectoryURL(fromPath: imageDir)
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
            .filter(Self.isSupportedImageFile)

        var records: [ImageRecord] = []
        for url in imageURLs {
            guard let record = createImageRecordFromURL(url) else { continue }
            records.append(record)
        }
        records.sort { $0.generatedDate < $1.generatedDate }
        return records
    }

    func importImages(from urls: [URL], imageDir: String) -> ([ImageRecord], Int) {
        var records: [ImageRecord] = []
        var failed = 0
        let destinationDirectory: URL

        do {
            destinationDirectory = try ensureOutputDirectory(imageDir: imageDir)
        } catch {
            return (records, urls.count)
        }

        for url in urls {
            guard Self.isSupportedImageFile(url), var record = createImageRecordFromURL(url) else {
                failed += 1
                continue
            }

            let importedURL = destinationDirectory.appending(path: url.lastPathComponent)
            do {
                try fileSystem.copyItem(at: url, to: importedURL)
            } catch {
                failed += 1
                continue
            }
            record.path = importedURL.path(percentEncoded: false)
            records.append(record)
        }

        return (records, failed)
    }

    func delete(path: String, moveToTrash: Bool) {
        guard !path.isEmpty else { return }

        let url = URL(fileURLWithPath: path, isDirectory: false)
        if moveToTrash {
            try? fileSystem.trashItem(at: url)
        } else {
            try? fileSystem.removeItem(at: url)
        }
    }

    func saveUpdatedImage(path: String, data: Data) -> URL? {
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
    ) -> URL? {
        let directoryURL = resolvedImageDirectoryURL(fromPath: imageDir)
        let filename = safeFilenameComponent(filenameWithoutExtension)
        let pathURL = directoryURL.appending(path: filename)
        let type = UTType.fromString(imageType)
        let availablePathURL = nextAvailablePathWithoutExtension(for: pathURL, type: type)
        return saveImageData(imageData, pathWithoutExtension: availablePathURL, type: type)
    }

    func ensureOutputDirectory(imageDir: String) throws -> URL {
        let directoryURL = resolvedImageDirectoryURL(fromPath: imageDir)
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

    func exportAllImages(_ images: [ImageExportRequest], to directory: URL, type: UTType) {
        for request in images {
            let filename = safeFilenameComponent(request.filenameWithoutExtension)
            let url = directory.appending(path: filename)
            let availableURL = nextAvailablePathWithoutExtension(for: url, type: type)
            _ = saveImageData(request.imageData, pathWithoutExtension: availableURL, type: type)
        }
    }

    func syncImages(imageDir: String, existingPaths: [String]) -> ImageSyncResult {
        let directoryURL = resolvedImageDirectoryURL(fromPath: imageDir)
        guard
            let fileList = try? fileSystem.contentsOfDirectory(at: directoryURL)
                .filter(Self.isSupportedImageFile)
                .map(\.lastPathComponent)
        else {
            return ImageSyncResult(additions: [], removals: [])
        }

        let existingSet = Set(existingPaths)
        var additions: [ImageRecord] = []
        var removals: [String] = []

        for filePath in fileList {
            if !existingSet.contains(where: { URL(filePath: $0).lastPathComponent == filePath }) {
                let fileURL = directoryURL.appending(component: filePath)
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

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Resolves the persisted empty-string spelling in one place, so load, import,
    /// generation and folder synchronization all mean the same directory.
    private func resolvedImageDirectoryURL(fromPath directory: String) -> URL {
        guard !directory.isEmpty else { return defaultImageDirectoryURL }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    /// Defense in depth for callers that already hand the repository a filename.
    /// Prompt sanitization happens earlier, but no repository operation may interpret
    /// a supplied filename as a relative or absolute path.
    private func safeFilenameComponent(_ filename: String) -> String {
        let component = URL(fileURLWithPath: filename).lastPathComponent
        guard !component.isEmpty, component != ".", component != ".." else {
            return "Image"
        }
        return component
    }

    /// Chooses a path without replacing an existing file.
    ///
    /// This check and the subsequent write happen without a suspension point on the
    /// repository actor, so two app writes cannot select the same candidate. An
    /// external process can still race the filesystem between the check and write;
    /// handling that would require an exclusive-create primitive rather than `Data`.
    private func nextAvailablePathWithoutExtension(
        for pathWithoutExtension: URL,
        type: UTType
    ) -> URL {
        let initialURL = pathWithoutExtension.appendingPathExtension(for: type)
        guard fileSystem.fileExists(initialURL) else {
            return pathWithoutExtension
        }

        let directory = pathWithoutExtension.deletingLastPathComponent()
        let baseName = pathWithoutExtension.lastPathComponent
        var suffix = 2

        while true {
            let candidatePath = directory.appending(path: "\(baseName)-\(suffix)")
            let candidateURL = candidatePath.appendingPathExtension(for: type)
            if !fileSystem.fileExists(candidateURL) {
                return candidatePath
            }
            suffix += 1
        }
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
