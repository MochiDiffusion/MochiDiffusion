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

    @Published
    private(set) var selectedId: SDImage.ID?

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

    func image(with index: Int) -> SDImage? {
        if images.isEmpty { return nil }
        if index < images.startIndex { return nil }
        if index > images.endIndex { return nil }
        return images[index]
    }

    func select(_ id: SDImage.ID) {
        selectedId = id
    }

    func select(_ index: Int) {
        if index < images.startIndex { return }
        if index > images.endIndex { return }
        selectedId = images[index].id
    }

    func selected() -> SDImage? {
        images.first { $0.id == selectedId }
    }

    func selectedIndex() -> Int {
        images.firstIndex { $0.id == selectedId } ?? -1
    }
}
