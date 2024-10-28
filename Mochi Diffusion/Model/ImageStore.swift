//
//  ImageStore.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/13/23.
//

import SwiftUI
import UniformTypeIdentifiers

enum ImagesSortType: String {
    case oldestFirst = "OLDEST_FIRST"
    case newestFirst = "NEWEST_FIRST"

    static let allValues: [ImagesSortType] = [.oldestFirst, .newestFirst]
}

@Observable public final class ImageStore {

    static let shared = ImageStore()

    private var allImages: [SDImage] = [] {
        didSet {
            updateFilteredImages()
            updateSortForImages()
        }
    }

    private(set) var images: [SDImage] = []

    private(set) var currentGeneratingImage: CGImage?

    private(set) var selectedId: SDImage.ID?

    var filters: [Filter] = [Filter]() {
        didSet {
            updateFilteredImages()
            updateSortForImages()
        }
    }

    @ObservationIgnored @AppStorage("GallerySort") private var _sortType: ImagesSortType =
        .oldestFirst
    @ObservationIgnored var sortType: ImagesSortType {
        get {
            access(keyPath: \.sortType)
            return _sortType
        }
        set {
            withMutation(keyPath: \.sortType) {
                _sortType = newValue
                updateSortForImages()
            }
        }
    }

    @discardableResult
    func add(_ sdi: SDImage) -> SDImage.ID {
        withAnimation {
            allImages.append(sdi)
            currentGeneratingImage = nil
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

    func setCurrentGenerating(image: CGImage?) {
        currentGeneratingImage = image
    }

    func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    func remove(_ sdis: [SDImage]) {
        withAnimation {
            allImages.removeAll { sdi in
                sdis.map { $0.id }.contains(sdi.id)
            }
        }
    }

    func remove(_ id: SDImage.ID) {
        withAnimation {
            guard let index = index(for: id) else { return }
            allImages.remove(at: index)
        }
    }

    /// Remove and delete image file.
    /// - Parameters:
    ///   - sdi: SDImage object to remove.
    ///   - moveToTrash: Whether image file should be moved to Trash or permanently deleted.
    func removeAndDelete(_ sdi: SDImage, moveToTrash: Bool) {
        remove(sdi.id)
        if sdi.path.isEmpty { return }
        if moveToTrash {
            try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: sdi.path, isDirectory: false), resultingItemURL: nil)
        } else {
            try? FileManager.default.removeItem(atPath: sdi.path)
        }
    }

    func removeAllExceptUnsaved() {
        for sdi in images where !sdi.path.isEmpty {
            guard let index = index(for: sdi.id) else { return }
            allImages.remove(at: index)
        }
    }

    func updateMetadata(_ sdi: SDImage, colorNumber: Int) {
        guard let index = index(for: sdi.id) else { return }
        allImages[index] = sdi
        allImages[index].finderTagColorNumber = colorNumber
    }

    func update(_ sdi: SDImage) {
        guard let index = index(for: sdi.id) else { return }
        allImages[index] = sdi
        if !sdi.path.isEmpty {
            Task {
                let url = URL(fileURLWithPath: sdi.path, isDirectory: false)
                let pathWithoutExtension = url.deletingPathExtension()
                let type = UTType.fromString(url.pathExtension.lowercased())

                guard let url = await sdi.save(pathWithoutExtension, type: type) else { return }
                allImages[index].path = url.path(percentEncoded: false)
            }
        }
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
        guard let id, let index = images.firstIndex(where: { $0.id == id }),
            index < images.count - 1
        else {
            return wrap ? images.first?.id : nil
        }
        return images[index + 1].id
    }

    private func updateFilteredImages() {
        if filters.isEmpty {
            images = allImages
        } else {
            images = allImages.filter(filters)
        }
    }

    private func updateSortForImages() {
        switch sortType {
        case .oldestFirst:
            images.sort(by: { $0.generatedDate < $1.generatedDate })
        case .newestFirst:
            images.sort(by: { $0.generatedDate > $1.generatedDate })
        }
    }
}

extension Array where Element == SDImage {
    fileprivate func filter(_ filters: [Filter]) -> [SDImage] {
        self.filter { image in
            filters.allSatisfy({ $0.validate(image) })
        }
    }
}
