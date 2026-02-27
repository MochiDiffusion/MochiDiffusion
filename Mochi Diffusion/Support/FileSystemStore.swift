//
//  FileSystemStore.swift
//  Mochi Diffusion
//

import Foundation

final class FileSystemStore {
    nonisolated init() {}

    nonisolated func directoryURL(
        fromPath directory: String,
        defaultingTo defaultPath: String
    ) -> URL {
        let fileManager = FileManager.default
        if directory.isEmpty {
            var url = fileManager.homeDirectoryForCurrentUser
            url.append(path: defaultPath, directoryHint: .isDirectory)
            return url
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    nonisolated func ensureDirectoryExists(_ url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    nonisolated func contentsOfDirectory(at url: URL) throws -> [URL] {
        let fileManager = FileManager.default
        return try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    nonisolated func subDirectories(in url: URL) throws -> [URL] {
        guard url.hasDirectoryPath else { return [] }
        return try contentsOfDirectory(at: url)
            .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
    }

    nonisolated func fileExists(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    nonisolated func isWritableDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.isWritableFile(atPath: url.path(percentEncoded: false))
    }

    nonisolated func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    nonisolated func removeItem(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.removeItem(at: url)
    }

    nonisolated func trashItem(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }
}
