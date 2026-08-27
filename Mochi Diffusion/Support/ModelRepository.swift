//
//  ModelRepository.swift
//  Mochi Diffusion
//

import Foundation

/// Filesystem paths and existence checks that are not any single engine's
/// business. Discovery itself moved into the engines: each applies its own
/// recognition rules to its own source, and nothing arbitrates between them.
///
/// `modelExists` is still here because `GenerationService` checks it before
/// generating. That is really an engine-runtime question — only the engine knows
/// what "present" means for its models, and a hosted model is never on disk at
/// all — so it moves in Phase 3.
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

    func modelExists(_ model: any EngineModel) -> Bool {
        fileSystem.fileExists(model.url)
    }

}
