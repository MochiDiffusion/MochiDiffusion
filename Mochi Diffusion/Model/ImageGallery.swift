//
//  ImageGallery.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/13/23.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum ImagesSortType: String {
    case oldestFirst = "OLDEST_FIRST"
    case newestFirst = "NEWEST_FIRST"

    static let allValues: [ImagesSortType] = [.oldestFirst, .newestFirst]
}

@MainActor
@Observable public final class ImageGallery {

    private let imageRepository: ImageRepository

    /// `nonisolated` because constructing a gallery only initialises stored
    /// properties, so it needs no main actor — and `MochiDiffusionApp.init` and
    /// `GenerationService`, both nonisolated, are the things that build one.
    nonisolated init(imageRepository: ImageRepository = ImageRepository()) {
        self.imageRepository = imageRepository
    }

    private(set) var allImages: [SDImage] = [] {
        didSet {
            updateFilteredImages()
            updateSortForImages()
        }
    }

    private(set) var images: [SDImage] = []

    private(set) var currentGeneratingImage: CGImage?
    /// Which request the preview belongs to.
    ///
    /// Results and progress events travel on separate channels, so a finished
    /// request's result can be applied *after* the next request has already put its
    /// first preview on screen. Without an owner, that result's teardown would
    /// erase a preview belonging to a generation still running.
    private(set) var currentGeneratingOwner: GenerationRequest.ID?

    private(set) var selectedId: SDImage.ID?
    private(set) var metadataFieldsByImageID: [SDImage.ID: Set<MetadataField>] = [:]

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
    func add(
        _ sdi: SDImage,
        metadataFields: Set<MetadataField> = Set(MetadataField.allCases),
        animate: Bool = true
    ) -> SDImage.ID {
        runWithOptionalAnimation(animate: animate) {
            allImages.append(sdi)
            metadataFieldsByImageID[sdi.id] = metadataFields
            return sdi.id
        }
    }

    @discardableResult
    func add(
        _ imagesAndMetadata: [(image: SDImage, metadataFields: Set<MetadataField>)],
        animate: Bool = true
    )
        -> [SDImage.ID]
    {
        runWithOptionalAnimation(animate: animate) {
            let images = imagesAndMetadata.map(\.image)
            allImages.append(contentsOf: images)
            for item in imagesAndMetadata {
                metadataFieldsByImageID[item.image.id] = item.metadataFields
            }
            return images.map(\.id)
        }
    }

    @discardableResult
    func add(_ sdis: [SDImage], animate: Bool = true) -> [SDImage.ID] {
        add(
            sdis.map { image in
                (image: image, metadataFields: Set(MetadataField.allCases))
            },
            animate: animate
        )
    }

    func replaceAll(_ imagesAndMetadata: [(image: SDImage, metadataFields: Set<MetadataField>)]) {
        withAnimation {
            allImages = imagesAndMetadata.map(\.image)

            var metadata: [SDImage.ID: Set<MetadataField>] = [:]
            for item in imagesAndMetadata {
                metadata[item.image.id] = item.metadataFields
            }
            metadataFieldsByImageID = metadata

            if let selectedId, !allImages.contains(where: { $0.id == selectedId }) {
                self.selectedId = nil
            }
        }
    }

    /// Shows `image` as `owner`'s in-progress preview, taking ownership of the slot.
    func setCurrentGenerating(image: CGImage, owner: GenerationRequest.ID) {
        let hadImage = currentGeneratingImage != nil
        runWithOptionalAnimation(animate: !hadImage) {
            currentGeneratingImage = image
            currentGeneratingOwner = owner
        }
    }

    /// Clears the preview only if `owner` still owns it.
    ///
    /// A request that has finished must not clear a preview the next one has already
    /// replaced, which is a real ordering: a result is delivered on its own channel
    /// and can be applied late.
    func clearCurrentGenerating(owner: GenerationRequest.ID) {
        guard currentGeneratingOwner == owner else { return }
        clearCurrentGenerating()
    }

    /// Clears the preview whoever owns it. For teardown paths that are ending
    /// generation altogether rather than finishing one request.
    func clearCurrentGenerating() {
        currentGeneratingImage = nil
        currentGeneratingOwner = nil
    }

    func remove(_ sdi: SDImage) {
        remove(sdi.id)
    }

    func remove(_ sdis: [SDImage]) {
        withAnimation {
            let removingIDs = Set(sdis.map(\.id))
            allImages.removeAll { sdi in
                removingIDs.contains(sdi.id)
            }
            for id in removingIDs {
                metadataFieldsByImageID[id] = nil
            }
        }
    }

    func remove(_ id: SDImage.ID) {
        withAnimation {
            guard let index = index(for: id) else { return }
            allImages.remove(at: index)
            metadataFieldsByImageID[id] = nil
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
        guard !sdi.path.isEmpty else { return }

        Task { @MainActor in
            let url = URL(fileURLWithPath: sdi.path, isDirectory: false)
            let type = UTType.fromString(url.pathExtension.lowercased())
            guard let data = await sdi.imageData(type) else { return }
            guard
                let savedURL = await imageRepository.saveUpdatedImage(
                    path: sdi.path,
                    data: data
                )
            else { return }
            guard let refreshedIndex = self.index(for: sdi.id) else { return }
            self.allImages[refreshedIndex].path = savedURL.path(percentEncoded: false)
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

    func metadataFields(for imageID: SDImage.ID) -> Set<MetadataField> {
        metadataFieldsByImageID[imageID] ?? Set(MetadataField.allCases)
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

    private func runWithOptionalAnimation<T>(animate: Bool, _ action: () -> T) -> T {
        if animate {
            return withAnimation {
                action()
            }
        }
        return action()
    }
}

extension Array where Element == SDImage {
    fileprivate func filter(_ filters: [Filter]) -> [SDImage] {
        self.filter { image in
            filters.allSatisfy({ $0.validate(image) })
        }
    }
}
