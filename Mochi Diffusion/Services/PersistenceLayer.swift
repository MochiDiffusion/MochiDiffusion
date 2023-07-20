//
//  PersistenceLayer.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/11/23.
//

import Foundation

enum PersistenceError: Error {
    case noDataAtURL
    case noModifiedDate
    case unknown
}

protocol PersistenceManager {
    func buildDirectory(defaultPath: String, electedPath: String?) -> URL
    func contents(of directory: URL) throws -> [String]
    func contents(of directory: URL) throws -> [URL]
    func copyItem(at: URL, to: URL) throws
    func createSymbolicLink(at url: URL, withDesinationURL destURL: URL) throws
    func delete(at url: URL, moveToTrash: Bool) throws
    func fileExists(at url: URL) -> Bool
    func getDateModified(for url: URL) throws -> Date
    func load(from url: URL) throws -> Data
    func save(data: Data, to url: URL) throws
    func subDirectories(of directory: URL) throws -> [URL]
}

struct LocalDiskPersistenceManager: PersistenceManager {

    private var fm: FileManager { FileManager.default }

    func copyItem(at: URL, to: URL) throws {
        try fm.copyItem(at: at, to: to)
    }

    func getDateModified(for url: URL) throws -> Date {
        let path = url.path(percentEncoded: false)
        let attributes = try fm.attributesOfItem(atPath: path)
        guard let date = attributes[FileAttributeKey.modificationDate] as? Date else {
            throw PersistenceError.noModifiedDate
        }
        return date
    }

    func createSymbolicLink(at url: URL, withDesinationURL destURL: URL) throws {
        try fm.createSymbolicLink(at: url, withDestinationURL: destURL)
    }

    func fileExists(at url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        return fm.fileExists(atPath: path)
    }

    func buildDirectory(defaultPath: String, electedPath: String?) -> URL {
        if let path = electedPath {
            return URL(fileURLWithPath: path, isDirectory: true)
        } else {
            return fm.homeDirectoryForCurrentUser.appending(path: defaultPath, directoryHint: .isDirectory)
        }
    }

    func subDirectories(of directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
    }

    func contents(of directory: URL) throws -> [String] {
        let path = directory.path(percentEncoded: false)
        return try fm.contentsOfDirectory(atPath: path)
    }

    func contents(of directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }

    func load(from url: URL) throws -> Data {
        guard let data = fm.contents(atPath: path(from: url)) else {
            throw PersistenceError.noDataAtURL
        }
        return data
    }

    func save(data: Data, to url: URL) throws {
        fm.createFile(atPath: path(from: url), contents: data)
    }

    func delete(at url: URL, moveToTrash: Bool) throws {
        if moveToTrash {
            try fm.trashItem(at: url, resultingItemURL: nil)
        } else {
            try fm.removeItem(at: url)
        }
    }

    private func path(from url: URL) -> String {
        url.path(percentEncoded: false)
    }
}
