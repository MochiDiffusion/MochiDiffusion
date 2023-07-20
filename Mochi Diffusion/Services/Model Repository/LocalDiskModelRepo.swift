//
//  LocalDiskModelRepo.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/12/23.
//

import Foundation

struct LocalDiskModelRepo: ModelRepo {

    private let modelDirPath: String?
    private let controlNetDirPath: String?
    private let persistenceManager: PersistenceManager

    private let modelDefaultPath = "MochiDiffusion/models/"
    private let controlNetDefaultPath = "MochiDiffusion/controlnet/"

    var modelURL: URL {
        persistenceManager
            .buildDirectory(defaultPath: modelDefaultPath, electedPath: modelDirPath)
    }
    var controlNetURL: URL {
        persistenceManager
            .buildDirectory(defaultPath: controlNetDefaultPath, electedPath: controlNetDirPath)
    }
    private var modelSubDirectories: [URL] {
        (try? persistenceManager
            .subDirectories(of: modelURL)
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }) ?? []
    }

    init(modelDirPath: String?, controlNetDirPath: String?, persistenceManager: PersistenceManager) {
        self.modelDirPath = modelDirPath
        self.controlNetDirPath = controlNetDirPath
        self.persistenceManager = persistenceManager
    }

    func loadModels() throws -> [SDModel] {
        let controlNets = loadControlNets()
        return modelSubDirectories.compactMap { url in
            let hasUnets = directoryHasUNets(url: url)
            if hasUnets { searchAndCreateUNets(at: url) }
            return SDModel(url: url, name: url.lastPathComponent, controlNet: hasUnets ? controlNets : [])
        }
    }

    private func searchAndCreateUNets(at url: URL) {
        let controlNetSymLinkURL = url.appending(component: "controlnet")
        if persistenceManager.fileExists(at: controlNetSymLinkURL) {
            try? persistenceManager.createSymbolicLink(at: controlNetSymLinkURL, withDesinationURL: controlNetURL)
        }
    }

    private func directoryHasUNets(url: URL) -> Bool {
        let unetURL = url.appending(components: "ControlledUnet.mlmodelc", "metadata.json")
        return persistenceManager.fileExists(at: unetURL)
    }

    private func loadControlNets() -> [String] {
        guard let nets: [String] = try? persistenceManager.contents(of: controlNetURL) else {
            return []
        }
        return nets
            .filter { !$0.hasPrefix(".") }
            .map { $0.replacing(".mlmodelc", with: "") }
    }
}
