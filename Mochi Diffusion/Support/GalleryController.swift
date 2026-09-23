//
//  GalleryController.swift
//  Mochi Diffusion
//
//  Created by Joshua Park on 2/12/23.
//

import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor
@Observable
final class GalleryController {
    private let logger = Logger()
    var configStore: ConfigStore
    var isLoading = true
    /// The gallery this controller loads into.
    ///
    /// Injected rather than reached for as `ImageGallery.shared`, so a test can give
    /// this controller its own gallery instead of mutating the one the app is
    /// showing. `loadImages()` replaces the whole contents, which is not something a
    /// test suite can do to a shared singleton and still run in parallel.
    private let imageGallery: ImageGallery
    private let imageRepository: ImageRepository
    private let focusController: FocusController
    /// The caches that have to be told when a file under a path changes.
    ///
    /// Held here because this controller is what changes them: it deletes, it
    /// imports, and it is what learns from the folder monitor that a file went
    /// away. The caches are keyed by path, so reusing a path — deleting an image
    /// and importing a different one under the same name is the way to do it
    /// without leaving the app — would otherwise serve the old pixels for both the
    /// grid and, through `GalleryFullImageProvider`, for export and generation
    /// input.
    ///
    /// Defaulted for tests, which want isolated caches; the app passes the ones it
    /// actually displays from.
    private let thumbnailProvider: GalleryThumbnailProvider
    private let fullImageProvider: GalleryFullImageProvider

    private var imageFolderMonitorTask: Task<Void, Never>?
    private var imageDirDebounceTask: Task<Void, Never>?
    /// Stored, and capturing weakly, so `shutdown()` can cancel it and it cannot
    /// outlive its owner.
    private var initialLoadTask: Task<Void, Never>?
    /// See `GenerationController.isShutDown`: cancelling tasks does not disarm a
    /// `withObservationTracking` callback, and firing is what re-arms it.
    private var isShutDown = false

    init(
        configStore: ConfigStore,
        imageGallery: ImageGallery,
        imageRepository: ImageRepository = ImageRepository(),
        focusController: FocusController,
        thumbnailProvider: GalleryThumbnailProvider = GalleryThumbnailProvider(),
        fullImageProvider: GalleryFullImageProvider = GalleryFullImageProvider()
    ) {
        self.configStore = configStore
        self.imageGallery = imageGallery
        self.imageRepository = imageRepository
        self.focusController = focusController
        self.thumbnailProvider = thumbnailProvider
        self.fullImageProvider = fullImageProvider
        initialLoadTask = Task { [weak self] in
            await self?.load()
        }
        startImageFolderMonitor()
        observeImageDir()
    }

    func load() async {
        isLoading = true
        await loadImages()
        isLoading = false
    }

    func loadImages() async {
        logger.info("Started loading images directory at: \"\(self.configStore.imageDir)\"")
        do {
            let records = try await imageRepository.load(
                imageDir: configStore.imageDir
            )
            let imagesAndMetadata = records.compactMap { record in
                createSDImage(from: record).map { image in
                    (image: image, metadataFields: record.metadataFields)
                }
            }
            let count = imagesAndMetadata.count

            logger.info("Found \(count) image(s)")

            imageGallery.replaceAll(imagesAndMetadata)
        } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
            logger.error("Couldn't access images directory at: \"\(path)\"")
        } catch {
            logger.error("There was a problem loading the images: \(error.localizedDescription)")
        }
    }

    func select(_ id: SDImage.ID) async {
        imageGallery.select(id)
        focusController.removeAllFocus()
    }

    func selectPrevious() async {
        guard let previous = imageGallery.imageBefore(imageGallery.selectedId) else {
            return
        }
        await select(previous)
    }

    func selectNext() async {
        guard let next = imageGallery.imageAfter(imageGallery.selectedId) else {
            return
        }
        await select(next)
    }

    func removeImage(_ sdi: SDImage) async {
        if sdi.id == imageGallery.selectedId {
            if let previous = imageGallery.imageBefore(sdi.id, wrap: false) {
                /// Move selection to the left, if possible.
                await select(previous)
            } else if let next = imageGallery.imageAfter(sdi.id, wrap: false) {
                /// When deleting the first image, move selection to the right.
                await select(next)
            }
        }

        imageGallery.remove(sdi)
        await imageRepository.delete(path: sdi.path, moveToTrash: configStore.useTrash)
        invalidateCaches(for: sdi.path)
    }

    /// Sets a Finder label on the image's file and tells the gallery. Zero clears
    /// every tag.
    ///
    /// Here rather than as a free function because the second half needs a gallery
    /// to tell, and a free function had nothing to reach for but the singleton.
    func setFinderTagColorNumber(_ sdi: SDImage, colorNumber: Int) {
        writeFinderTagColorNumber(sdi.path, colorNumber: colorNumber)
        imageGallery.updateMetadata(sdi, colorNumber: colorNumber)
    }

    func clearFinderTags(_ sdi: SDImage) {
        setFinderTagColorNumber(sdi, colorNumber: 0)
    }

    func removeCurrentImage() async {
        guard let sdi = imageGallery.selected() else { return }
        await removeImage(sdi)
    }

    func importImages() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = String(localized: "Choose generated images to import")
        panel.prompt = String(localized: "Import", comment: "OK button text for import image panel")
        let resp = await ModalPresentation.present(panel)
        if resp != .OK {
            return
        }

        let selectedURLs = panel.urls
        if selectedURLs.isEmpty { return }

        isLoading = true
        let (records, failed) = await imageRepository.importImages(
            from: selectedURLs, imageDir: configStore.imageDir)
        let imagesAndMetadata = records.compactMap { record in
            createSDImage(from: record).map { image in
                (image: image, metadataFields: record.metadataFields)
            }
        }
        // Before the gallery shows them: an imported file can land on a path some
        // earlier image was cached under, whether this session deleted it or
        // something else did.
        for record in records {
            invalidateCaches(for: record.path)
        }
        let succeeded = imagesAndMetadata.count
        imageGallery.add(imagesAndMetadata)
        isLoading = false

        let alert = NSAlert()
        alert.messageText = String(localized: "Imported \(succeeded) image(s)")
        if failed > 0 {
            alert.informativeText = String(
                localized:
                    "\(failed) image(s) were not imported. Only images generated by Mochi Diffusion 2.2 or later can be imported."
            )
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        await ModalPresentation.present(alert)
    }

    func saveAll() async {
        if imageGallery.images.isEmpty { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = String(localized: "Choose a folder to save all images")
        panel.prompt = String(localized: "Save")
        let resp = await ModalPresentation.present(panel)
        if resp != .OK {
            return
        }

        guard let selectedURL = panel.url else { return }
        let type = UTType.fromString(configStore.imageType)

        let images = imageGallery.images
        var exportRequests: [ImageExportRequest] = []
        exportRequests.reserveCapacity(images.count)
        for (index, sdi) in images.enumerated() {
            let count = index + 1
            // The fields this image actually recorded, not every field Mochi can
            // write. An imported image that carried only a prompt must not gain a
            // scheduler and step count on the way out.
            let metadataFields = imageGallery.metadataFields(for: sdi.id)
            guard let data = await sdi.imageData(type, metadataFields: metadataFields) else {
                continue
            }
            exportRequests.append(
                ImageExportRequest(
                    filenameWithoutExtension: sdi.filenameWithoutExtension(count: count),
                    imageData: data
                )
            )
        }

        await imageRepository.exportAllImages(exportRequests, to: selectedURL, type: type)
    }

    func copyImage(_ sdi: SDImage) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let metadataFields = imageGallery.metadataFields(for: sdi.id)
        guard let imageData = await sdi.imageData(.png, metadataFields: metadataFields) else {
            return
        }
        guard let image = NSImage(data: imageData) else { return }
        pasteboard.writeObjects([image])
    }

    private func observeImageDir() {
        guard !isShutDown else { return }
        withObservationTracking {
            _ = configStore.imageDir
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.scheduleImageDirUpdate()
                self?.observeImageDir()
            }
        }
    }

    private func scheduleImageDirUpdate() {
        guard !isShutDown else { return }
        imageDirDebounceTask?.cancel()
        imageDirDebounceTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return
            }
            await updateImageFolderMonitor()
        }
    }

    private func updateImageFolderMonitor() async {
        startImageFolderMonitor()
        // A different folder can hold the same file names as the last one, and the
        // caches key on path alone.
        await thumbnailProvider.invalidate()
        await fullImageProvider.invalidate()
        await loadImages()
    }

    private func startImageFolderMonitor() {
        guard !isShutDown else { return }
        imageFolderMonitorTask?.cancel()
        let path = imageDirectoryPath()
        imageFolderMonitorTask = Task { [weak self] in
            // Weak inside the loop rather than hoisted before it: the loop never
            // ends on its own, so a strong `self` here would keep the task and the
            // controller alive indefinitely.
            let stream = await FolderMonitorService.shared.updates(for: path)
            for await _ in stream {
                guard let self else { return }
                await self.syncImages()
            }
        }
    }

    /// Cancels every task this controller owns and stops it starting new ones.
    /// See `GenerationController.shutdown()`.
    func shutdown() {
        isShutDown = true
        initialLoadTask?.cancel()
        imageFolderMonitorTask?.cancel()
        imageDirDebounceTask?.cancel()
        initialLoadTask = nil
        imageFolderMonitorTask = nil
        imageDirDebounceTask = nil
    }

    private func imageDirectoryPath() -> String {
        ImageRepository.imageDirectoryURL(fromPath: configStore.imageDir)
            .path(percentEncoded: false)
    }

    /// Tells both caches that whatever was at `path` is no longer what is there.
    ///
    /// Synchronous: both calls are `nonisolated`, so this happens at the moment the
    /// file changes rather than after a hop that a read could get in front of.
    private func invalidateCaches(for path: String) {
        thumbnailProvider.invalidate(path: path)
        fullImageProvider.invalidate(path: path)
    }

    private func syncImages() async {
        let imageDir = imageDirectoryPath()
        let existingPaths = imageGallery.allImages.compactMap { sdi in
            sdi.path.isEmpty ? nil : sdi.path
        }

        let result = await imageRepository.syncImages(
            imageDir: imageDir,
            existingPaths: existingPaths
        )

        if !result.additions.isEmpty {
            let additions = result.additions.compactMap { record in
                createSDImage(from: record).map { image in
                    (image: image, metadataFields: record.metadataFields)
                }
            }
            imageGallery.add(additions)
        }

        if !result.removals.isEmpty {
            // Covers a deletion this app did not perform. `syncImages` compares
            // file names, so this is every disappearance it can see.
            for path in result.removals {
                invalidateCaches(for: path)
            }
            let removals = imageGallery.allImages.filter {
                result.removals.contains($0.path)
            }
            imageGallery.remove(removals)
        }
    }
}
