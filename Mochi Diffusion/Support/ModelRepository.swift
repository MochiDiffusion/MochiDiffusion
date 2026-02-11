//
//  ModelRepository.swift
//  Mochi Diffusion
//

import Foundation

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

    func load(modelDir: URL, controlNetDir: URL) async throws -> [any MochiModel] {
        var models: [any MochiModel] = []
        let fm = FileManager.default

        do {
            let controlNet = controlNets(in: controlNetDir)
            let subDirs = try fileSystem.subDirectories(in: modelDir)

            models =
                subDirs
                .sorted {
                    $0.lastPathComponent.compare(
                        $1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive])
                        == .orderedAscending
                }
                .compactMap { url in
                    if let flux2cModel = Flux2cModel(url: url, name: url.lastPathComponent) {
                        return flux2cModel
                    }

                    let controlledUnetMetadataPath = url.appending(
                        components: "ControlledUnet.mlmodelc", "metadata.json"
                    ).path(percentEncoded: false)
                    let hasControlNet = fm.fileExists(atPath: controlledUnetMetadataPath)

                    if hasControlNet {
                        let controlNetSymLinkPath = url.appending(component: "controlnet").path(
                            percentEncoded: false)

                        if !fm.fileExists(atPath: controlNetSymLinkPath) {
                            try? fm.createSymbolicLink(
                                atPath: controlNetSymLinkPath,
                                withDestinationPath: controlNetDir.path(
                                    percentEncoded: false))
                        }
                    }

                    return SDModel(
                        url: url, name: url.lastPathComponent,
                        controlNet: hasControlNet ? controlNet : [])
                }
        } catch {
            throw SDImageGenerator.GeneratorError.modelSubDirectoriesNoAccess
        }
        if models.isEmpty {
            throw SDImageGenerator.GeneratorError.noModelsFound
        }
        return models
    }

    func modelExists(_ model: any MochiModel) async -> Bool {
        fileSystem.fileExists(model.url)
    }

    private func controlNets(in controlNetDirectoryURL: URL) -> [SDControlNet] {
        guard fileSystem.fileExists(controlNetDirectoryURL),
            let contentsOfControlNet = try? fileSystem.contentsOfDirectory(
                at: controlNetDirectoryURL)
        else {
            return []
        }

        return contentsOfControlNet.compactMap { SDControlNet(url: $0) }
    }
}
