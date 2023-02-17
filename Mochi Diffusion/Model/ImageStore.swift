//
//  ImageStore.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/13/23.
//

import SwiftUI

@MainActor
class ImageStore: ObservableObject {

    static let shared = ImageStore()

    @Published
    private(set) var images: [SDImage] = []

    func filter(_ text: String) -> [SDImage] {
        images.filter {
            $0.prompt.range(of: text, options: .caseInsensitive) != nil ||
            $0.seed == UInt32(text)
        }
    }

    @discardableResult
    func add(_ sdi: SDImage) -> SDImage.ID {
        withAnimation {
            images.append(sdi)
            return sdi.id
        }
    }

    @discardableResult
    func add(_ sdis: [SDImage]) -> [SDImage.ID] {
        withAnimation {
            images.append(contentsOf: sdis)
            return sdis.map { $0.id }
        }
    }

    func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    func remove(_ id: SDImage.ID) {
        withAnimation {
            guard let index = index(for: id) else { return }
            images.remove(at: index)
        }
    }

    func update(_ sdi: SDImage) {
        guard let index = index(for: sdi.id) else { return }
        images[index] = sdi
    }

    func index(for id: SDImage.ID) -> Int? {
        images.firstIndex { $0.id == id }
    }

    func image(with id: SDImage.ID) -> SDImage? {
        images.first { $0.id == id }
    }
}
