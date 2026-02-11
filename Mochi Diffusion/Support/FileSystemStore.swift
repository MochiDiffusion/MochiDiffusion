//
//  FileSystemStore.swift
//  Mochi Diffusion
//

import Foundation

final class FileSystemStore {
    private let fileManager = FileManager.default

    init() {}

    func directoryURL(fromPath directory: String, defaultingTo defaultPath: String) -> URL {
        if directory.isEmpty {
            var url = fileManager.homeDirectoryForCurrentUser
            url.append(path: defaultPath, directoryHint: .isDirectory)
            return url
        }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    func ensureDirectoryExists(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }

    func subDirectories(in url: URL) throws -> [URL] {
        guard url.hasDirectoryPath else { return [] }
        return try contentsOfDirectory(at: url)
            .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
    }

    func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path(percentEncoded: false))
    }

    func isWritableDirectory(_ url: URL) -> Bool {
        fileManager.isWritableFile(atPath: url.path(percentEncoded: false))
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func trashItem(at url: URL) throws {
        try fileManager.trashItem(at: url, resultingItemURL: nil)
    }
}
