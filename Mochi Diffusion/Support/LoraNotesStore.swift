//
//  LoraNotesStore.swift
//  Mochi Diffusion
//

import Foundation
import os

final class LoraNotesStore {
    private static let notesFilename = "lora-notes.plist"
    private static let appSupportSubdirectory = "MochiDiffusion"

    private let fileSystem: FileSystemStore
    private let logger = Logger()

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    func load() -> [String: String] {
        let notesURL = notesURL()
        guard let data = try? Data(contentsOf: notesURL) else {
            return [:]
        }

        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let notes = plist as? [String: String]
        else {
            logger.error(
                "LoRA notes plist at \"\(notesURL.path(percentEncoded: false))\" is invalid."
            )
            return [:]
        }

        return notes
    }

    func save(_ notes: [String: String]) {
        let notesURL = notesURL()
        let appSupportURL = appSupportDirectoryURL()

        if notes.isEmpty {
            try? fileSystem.removeItem(at: notesURL)
            return
        }

        do {
            try fileSystem.ensureDirectoryExists(appSupportURL)
            let data = try PropertyListSerialization.data(
                fromPropertyList: notes,
                format: .xml,
                options: 0
            )
            try data.write(to: notesURL, options: .atomic)
        } catch {
            logger.error("Could not save LoRA notes plist: \(error.localizedDescription)")
        }
    }

    private func notesURL() -> URL {
        appSupportDirectoryURL().appending(path: Self.notesFilename, directoryHint: .notDirectory)
    }

    private func appSupportDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let baseURL =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appending(
                path: "Library/Application Support"
            )
        return baseURL.appending(path: Self.appSupportSubdirectory, directoryHint: .isDirectory)
    }
}
