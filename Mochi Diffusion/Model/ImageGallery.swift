//
//  ImageGallery.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/13/23.
//

import Foundation
import SwiftUI

enum ImagesSortType: String {
    case oldestFirst = "OLDEST_FIRST"
    case newestFirst = "NEWEST_FIRST"
}

@MainActor
@Observable final class ImageGallery {

    /// `nonisolated` so `MochiDiffusionApp.init` and `GenerationService` can call
    /// it; safe because it only initialises stored properties.
    nonisolated init() {}

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
    /// first preview on screen. The owner keeps that result's teardown from erasing
    /// the running generation's preview.
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

    /// Adds `sdi` unless the gallery already holds its file. See
    /// `add(_:animate:)` for the rule. Returns nil when the image was skipped.
    @discardableResult
    func add(
        _ sdi: SDImage,
        metadataFields: Set<MetadataField> = Set(MetadataField.allCases),
        animate: Bool = true
    ) -> SDImage.ID? {
        add([(image: sdi, metadataFields: metadataFields)], animate: animate).first
    }

    /// Adds the images whose files the gallery does not already hold, and returns
    /// the IDs of those it added.
    ///
    /// The gallery mirrors one images folder, so it holds at most one entry per
    /// file. A folder sync can find a file at the same time as an import or a
    /// generation result adds it, and whichever arrives second is skipped. Files
    /// are compared by name, because loading and writing can spell the folder's
    /// path differently. An image with no path is always added.
    @discardableResult
    func add(
        _ imagesAndMetadata: [(image: SDImage, metadataFields: Set<MetadataField>)],
        animate: Bool = true
    )
        -> [SDImage.ID]
    {
        var heldFileNames = Set(allImages.compactMap(Self.fileName(of:)))
        let newItems = imagesAndMetadata.filter { item in
            guard let fileName = Self.fileName(of: item.image) else { return true }
            return heldFileNames.insert(fileName).inserted
        }
        guard !newItems.isEmpty else { return [] }
        return runWithOptionalAnimation(animate: animate) {
            let images = newItems.map(\.image)
            allImages.append(contentsOf: images)
            for item in newItems {
                metadataFieldsByImageID[item.image.id] = item.metadataFields
            }
            return images.map(\.id)
        }
    }

    private static func fileName(of image: SDImage) -> String? {
        image.path.isEmpty ? nil : URL(fileURLWithPath: image.path).lastPathComponent
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
    /// A result is delivered on its own channel and can be applied late, so a
    /// finished request must not clear a preview the next one has already replaced.
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

    func index(for id: SDImage.ID) -> Int? {
        allImages.firstIndex { $0.id == id }
    }

    /// Finds a related gallery image by the basename recorded in image metadata.
    ///
    /// Metadata records only the source filename. The comparison ignores case and
    /// diacritics, since filesystems and imported captions may disagree about both.
    func image(named filename: String) -> SDImage? {
        guard let basename = filename.normalizedFilename else { return nil }
        return allImages.first { image in
            URL(fileURLWithPath: image.path).lastPathComponent.compare(
                basename,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
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
