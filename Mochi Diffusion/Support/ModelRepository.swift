//
//  ModelRepository.swift
//  Mochi Diffusion
//

import Foundation

/// Filesystem paths and existence checks that are not any single engine's
/// business. Discovery itself belongs to the engines: each applies its own
/// recognition rules to its own source, and nothing arbitrates between them.
///
/// `modelExists(at:)` serves engines whose models are local directories. What
/// "present" means is ultimately an engine's own question — a hosted model is
/// never on disk at all — so a hosted engine answers it for itself rather than
/// coming here. It takes a `URL` rather than an `any EngineModel` for that
/// reason: only an engine that has a directory can ask.
actor ModelRepository {
    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    nonisolated static func modelDirectoryURL(fromPath directory: String) -> URL {
        FileSystemStore().directoryURL(
            fromPath: directory,
            defaultingTo: "MochiDiffusion/models"
        )
    }

    nonisolated static func controlNetDirectoryURL(fromPath directory: String) -> URL {
        FileSystemStore().directoryURL(
            fromPath: directory,
            defaultingTo: "MochiDiffusion/controlnet"
        )
    }

    func modelExists(at url: URL) -> Bool {
        fileSystem.fileExists(url)
    }

}
