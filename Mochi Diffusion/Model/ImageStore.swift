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

    private var allImages: [SDImage] = [] {
        didSet {
            updateFilteredImages()
        }
    }

    @Published
    private(set) var images: [SDImage] = []

    @Published
    private(set) var selectedId: SDImage.ID?

    @Published
    var searchText: String = "" {
        didSet {
            updateFilteredImages()
        }
    }

    @discardableResult
    func add(_ sdi: SDImage) -> SDImage.ID {
        withAnimation {
            allImages.append(sdi)
            return sdi.id
        }
    }

    @discardableResult
    func add(_ sdis: [SDImage]) -> [SDImage.ID] {
        withAnimation {
            allImages.append(contentsOf: sdis)
            return sdis.map { $0.id }
        }
    }

    func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    func remove(_ id: SDImage.ID) {
        withAnimation {
            guard let index = index(for: id) else { return }
            allImages.remove(at: index)
        }
    }

    func update(_ sdi: SDImage) {
        guard let index = index(for: sdi.id) else { return }
        allImages[index] = sdi
    }

    func index(for id: SDImage.ID) -> Int? {
        allImages.firstIndex { $0.id == id }
    }

    func image(with id: SDImage.ID) -> SDImage? {
        allImages.first { $0.id == id }
    }

    func image(with index: Int) -> SDImage? {
        if allImages.isEmpty { return nil }
        if index < allImages.startIndex { return nil }
        if index > allImages.endIndex { return nil }
        return allImages[index]
    }

    func select(_ id: SDImage.ID) {
        selectedId = id
    }

    func selected() -> SDImage? {
        allImages.first { $0.id == selectedId }
    }

    func imageBefore(_ id: SDImage.ID?, wrap: Bool = true) -> SDImage.ID? {
        guard let id, let index = images.firstIndex(where: { $0.id == id }), index > 0 else {
            return wrap ? images.last?.id : nil
        }

        return images[index - 1].id
    }

    func imageAfter(_ id: SDImage.ID?, wrap: Bool = true) -> SDImage.ID? {
        guard let id, let index = images.firstIndex(where: { $0.id == id }), index < images.count - 1 else {
            return wrap ? images.first?.id : nil
        }

        return images[index + 1].id
    }

    private func updateFilteredImages() {
        if searchText.isEmpty {
            images = allImages
        } else {
            images = allImages.filter(searchText)
        }
    }
}

private extension Array where Element == SDImage {
    func filter(_ text: String) -> [SDImage] {
        self.filter {
            $0.prompt.range(of: text, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil ||
            $0.seed == UInt32(text)
        }
    }
}
