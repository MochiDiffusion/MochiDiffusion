//
//  LocalEngines.swift
//  Mochi Diffusion
//

import Foundation

/// Core ML Stable Diffusion: models converted with Apple's `ml-stable-diffusion`,
/// each a directory of `.mlmodelc` bundles.
nonisolated struct CoreMLStableDiffusionEngine: GenerationEngineDescriptor {
    typealias Model = SDModel

    static let id = EngineID.coreMLStableDiffusion
    var displayName: String { "Core ML Stable Diffusion" }

    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard fileSystem.fileExists(settings.modelDirectory) else {
            return .unreachable(
                String(
                    localized: "Models folder not found",
                    comment: "Engine unavailable because its models folder is missing"
                )
            )
        }
        return .ready
    }

    func discoverModels(_ settings: EngineSettings) async throws -> [SDModel] {
        let controlNets = controlNets(in: settings.controlNetDirectory)
        return try fileSystem.subDirectories(in: settings.modelDirectory)
            .compactMap { url in
                linkControlNetDirectoryIfNeeded(
                    for: url, controlNetDir: settings.controlNetDirectory)
                return SDModel(
                    url: url,
                    name: ModelID.localKey(for: url),
                    controlNet: hasControlNet(url) ? controlNets : []
                )
            }
    }

    private func hasControlNet(_ url: URL) -> Bool {
        fileSystem.fileExists(url.appending(components: "ControlledUnet.mlmodelc", "metadata.json"))
    }

    /// A ControlNet-capable model needs the ControlNet bundles reachable from
    /// inside its own directory, so discovery drops a symlink in.
    ///
    /// A write during discovery is a side effect that does not belong on a read
    /// path — it fires on every folder-change event, and it mutates the user's
    /// models folder. Preserved as-is here because this step is a refactor;
    /// pipeline loading is where it belongs, which is the runtime's job in Phase 3.
    private func linkControlNetDirectoryIfNeeded(for url: URL, controlNetDir: URL) {
        guard hasControlNet(url) else { return }
        let link = url.appending(component: "controlnet")
        guard !fileSystem.fileExists(link) else { return }
        try? FileManager.default.createSymbolicLink(
            atPath: link.path(percentEncoded: false),
            withDestinationPath: controlNetDir.path(percentEncoded: false)
        )
    }

    private func controlNets(in directory: URL) -> [SDControlNet] {
        guard fileSystem.fileExists(directory),
            let contents = try? fileSystem.contentsOfDirectory(at: directory)
        else {
            return []
        }
        return contents.compactMap { SDControlNet(url: $0) }
    }
}

/// Iris: FLUX.2 and Z-Image models in diffusers layout, run through the bundled
/// Iris library.
nonisolated struct IrisEngine: GenerationEngineDescriptor {
    typealias Model = IrisFluxKleinModel

    static let id = EngineID.iris
    var displayName: String { "Iris" }

    private let fileSystem: FileSystemStore

    init(fileSystem: FileSystemStore = FileSystemStore()) {
        self.fileSystem = fileSystem
    }

    func availability(_ settings: EngineSettings) async -> EngineAvailability {
        guard fileSystem.fileExists(settings.modelDirectory) else {
            return .unreachable(
                String(
                    localized: "Models folder not found",
                    comment: "Engine unavailable because its models folder is missing"
                )
            )
        }
        return .ready
    }

    func discoverModels(_ settings: EngineSettings) async throws -> [IrisFluxKleinModel] {
        try fileSystem.subDirectories(in: settings.modelDirectory)
            .compactMap { IrisFluxKleinModel(url: $0, name: ModelID.localKey(for: $0)) }
    }
}
