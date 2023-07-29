//
//  LocalDiskModelRepo.swift
//  Mochi Diffusion
//
//  Created by Jeffrey Thompson on 7/12/23.
//

import Foundation

struct ModelRepo {

    private let modelDirPath: String?
    private let controlNetDirPath: String?
    private let fm = FileManager.default

    private let modelDefaultPath = "MochiDiffusion/models/"
    private let controlNetDefaultPath = "MochiDiffusion/controlnet/"

    var modelURL: URL {
        fm.buildDirectory(defaultPath: modelDefaultPath, electedPath: modelDirPath)
    }
    var controlNetURL: URL {
        fm.buildDirectory(defaultPath: controlNetDefaultPath, electedPath: controlNetDirPath)
    }
    private var modelSubDirectories: [URL] {
        (try? fm
            .contentsOfDirectory(at: modelURL, includingPropertiesForKeys: nil)
            .filter { $0.resolvingSymlinksInPath().hasDirectoryPath }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedAscending }) ?? []
    }

    init(modelDirPath: String?, controlNetDirPath: String?) {
        self.modelDirPath = modelDirPath
        self.controlNetDirPath = controlNetDirPath
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
        if fm.fileExists(atPath: controlNetSymLinkURL.path(percentEncoded: false)) {
            try? fm.createSymbolicLink(at: controlNetSymLinkURL, withDestinationURL: controlNetURL)
        }
    }

    private func directoryHasUNets(url: URL) -> Bool {
        let unetURL = url.appending(components: "ControlledUnet.mlmodelc", "metadata.json")
        return fm.fileExists(atPath: unetURL.path(percentEncoded: false))
    }

    private func loadControlNets() -> [String] {
        let path = controlNetURL.path(percentEncoded: false)
        guard let nets: [String] = try? fm.contentsOfDirectory(atPath: path) else {
            return []
        }
        return nets
            .filter { !$0.hasPrefix(".") }
            .map { $0.replacing(".mlmodelc", with: "") }
    }
}
