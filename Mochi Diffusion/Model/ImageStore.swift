//
//  ImageStore.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/13/23.
//

import SwiftUI

@MainActor
class ImageStore {

    @Published
    private(set) var images: [SDImage] = []

    func filter(_ text: String) -> [SDImage] {
        images.filter {
            $0.prompt.range(of: text, options: .caseInsensitive) != nil ||
            $0.seed == UInt32(text)
        }
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
}
