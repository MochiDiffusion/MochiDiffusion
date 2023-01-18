//
//  ImageStore.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 1/18/23.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class ImageStore: ObservableObject {
    @Published var images: [SDImage]

    init(_ images: [SDImage]) {
        self.images = images
    }

    func add(_ sdi: SDImage) -> SDImage.ID {
        var sdiToAdd = sdi
        sdiToAdd.id = UUID()
        images.append(sdiToAdd)
        return sdiToAdd.id
    }

    func add(_ sdis: [SDImage]) {
        images.append(contentsOf: sdis)
    }

    func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    func remove(_ id: SDImage.ID) {
        if let index = index(for: id) {
            images.remove(at: index)
        }
    }

    func update(_ sdi: SDImage) {
        if let index = index(for: sdi.id) {
            images[index] = sdi
        }
    }

    func index(for id: SDImage.ID) -> Int? {
        images.firstIndex { $0.id == id }
    }

    func image(with id: UUID) -> SDImage? {
        images.first { $0.id == id }
    }

    func saveAllImages() {
        if images.isEmpty { return }
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder to save all images"
        panel.prompt = "Save"
        let resp = panel.runModal()
        if resp != .OK {
            return
        }

        guard let selectedURL = panel.url else { return }
        var count = 1
        for sdi in images {
            let url = selectedURL.appending(path: "\(String(sdi.prompt.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)).\(count).\(sdi.seed).png")
            guard let image = sdi.image else { return }
            guard let data = CFDataCreateMutable(nil, 0) else { return }
            guard let destination = CGImageDestinationCreateWithData(
                data,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return
            }
            let iptc = [
                kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                kCGImagePropertyIPTCCaptionAbstract: sdi.metadata(),
                kCGImagePropertyIPTCProgramVersion: "\(NSApplication.appVersion)"
            ]
            let meta = [kCGImagePropertyIPTCDictionary: iptc]
            CGImageDestinationAddImage(destination, image, meta as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return }
            do {
                try (data as Data).write(to: url)
            } catch {
                NSLog("*** Error saving images: \(error)")
            }
            count += 1
        }
    }
}
