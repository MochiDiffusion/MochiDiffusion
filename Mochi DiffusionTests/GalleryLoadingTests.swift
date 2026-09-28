//
//  GalleryLoadingTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Gallery loading, into a gallery each test owns. `loadImages()` replaces the
/// gallery's whole contents, so a shared gallery would race other suites.
@MainActor
struct GalleryLoadingTests {
    let temp: TempDirectory
    let defaults: TempDefaults
    let imageDir: URL

    init() throws {
        temp = try TempDirectory()
        defaults = TempDefaults()
        imageDir = try temp.subdirectory("images")
    }

    private func makeController(
        gallery: ImageGallery,
        thumbnailProvider: GalleryThumbnailProvider = GalleryThumbnailProvider(),
        fullImageProvider: GalleryFullImageProvider = GalleryFullImageProvider()
    ) -> GalleryController {
        let configStore = ConfigStore(store: defaults.defaults)
        configStore.imageDir = imageDir.path(percentEncoded: false)
        return GalleryController(
            configStore: configStore,
            imageGallery: gallery,
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
    }

    /// A controller that has finished its initial load and whose folder monitor
    /// is stopped, so every folder sync in the test is one the test asked for.
    private func makeSettledController(
        gallery: ImageGallery,
        thumbnailProvider: GalleryThumbnailProvider = GalleryThumbnailProvider(),
        fullImageProvider: GalleryFullImageProvider = GalleryFullImageProvider()
    ) async throws -> GalleryController {
        let controller = makeController(
            gallery: gallery,
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
        while controller.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        controller.shutdown()
        return controller
    }

    /// Writes an importable image: the version gate rejects anything without a
    /// `Generator` key naming 2.2 or later.
    private func writeImportableImage(
        named name: String,
        prompt: String,
        in directory: URL? = nil,
        image: CGImage = makeCGImage()
    ) throws {
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, prompt),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: (directory ?? imageDir).appending(path: name),
            image: image
        )
    }

    @Test("Loading fills the gallery it was given")
    func loadsIntoItsOwnGallery() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        try writeImportableImage(named: "two.png", prompt: "a dog")
        let gallery = ImageGallery()
        let controller = makeController(gallery: gallery)

        await controller.loadImages()

        #expect(gallery.images.count == 2)
        #expect(Set(gallery.images.map(\.prompt)) == ["a cat", "a dog"])
        controller.shutdown()
    }

    @Test("Two galleries do not see each other's contents")
    func galleriesAreIndependent() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        let loaded = ImageGallery()
        let untouched = ImageGallery()
        let controller = makeController(gallery: loaded)

        await controller.loadImages()

        #expect(loaded.images.count == 1)
        #expect(untouched.images.isEmpty)
        controller.shutdown()
    }

    @Test("An images folder with nothing importable loads empty")
    func unimportableImagesAreSkipped() async throws {
        // No `Generator` key, so the version gate rejects it — the same path a
        // third-party PNG dropped in the folder takes.
        try writePNG(caption: "Include in Image: a cat", to: imageDir.appending(path: "raw.png"))
        let gallery = ImageGallery()
        let controller = makeController(gallery: gallery)

        await controller.loadImages()

        #expect(gallery.images.isEmpty)
        controller.shutdown()
    }

    /// A decoded 1024x1024 image is about 4 MB, so gallery images are not decoded
    /// at load.
    @Test("A loaded image carries no decoded pixels, but knows its size")
    func loadedImagesAreNotDecoded() async throws {
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, "a cat"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: imageDir.appending(path: "one.png"),
            image: makeCGImage(width: 96, height: 48)
        )
        let gallery = ImageGallery()
        let controller = makeController(gallery: gallery)

        await controller.loadImages()
        let sdi = try #require(gallery.images.first)

        #expect(sdi.image == nil)
        // Read from the file's properties, which needs no decode.
        #expect(sdi.width == 96)
        #expect(sdi.height == 48)
        #expect(sdi.aspectRatio == 2)
        controller.shutdown()
    }

    @Test("A disk-backed selection exposes metadata to the inspector")
    func diskBackedSelectionHasInspectorMetadata() async throws {
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, "a cat wearing a hat"),
                (.model, "test-model"),
                (.seed, "123"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: imageDir.appending(path: "one.png")
        )
        let gallery = ImageGallery()
        let controller = makeController(gallery: gallery)

        await controller.loadImages()
        let loaded = try #require(gallery.images.first)
        #expect(loaded.image == nil)
        gallery.select(loaded.id)

        let selection = try #require(InspectorSelection(gallery: gallery))
        #expect(selection.image.prompt == "a cat wearing a hat")
        #expect(selection.image.model == "test-model")
        #expect(selection.image.seed == 123)
        #expect(selection.metadataFields == [.prompt, .model, .seed])
        controller.shutdown()
    }

    @Test("Related images resolve by basename without case or accent sensitivity")
    func relatedImageFilenameLookupIsForgiving() {
        let gallery = ImageGallery()
        let related = SDImage(
            image: nil,
            aspectRatio: 1,
            path: imageDir.appending(path: "RÉFÉRENCE.PNG").path(percentEncoded: false)
        )
        gallery.replaceAll([(image: related, metadataFields: [])])

        #expect(gallery.image(named: "reference.png")?.id == related.id)
        #expect(gallery.image(named: "  RÉFÉRENCE.PNG  ")?.id == related.id)
        #expect(gallery.image(named: "") == nil)
        #expect(gallery.image(named: "missing.png") == nil)
    }

    /// Save As, Save All and Copy all go through `exportPNGData`, and gallery
    /// images loaded from disk have no resident pixels.
    @Test("Export reads the file when no pixels are resident")
    func exportReadsFromDisk() async throws {
        let url = imageDir.appending(path: "one.png")
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, "a cat"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: url,
            image: makeCGImage(width: 64, height: 32)
        )
        var sdi = SDImage(image: nil, aspectRatio: 2, path: url.path(percentEncoded: false))
        sdi.width = 64
        sdi.height = 32

        let data = try #require(await sdi.exportPNGData())

        #expect(pixelSize(of: data) == CGSize(width: 64, height: 32))
    }

    @Test("An image with no file has nothing to export")
    func exportWithoutSourceIsNil() async {
        let sdi = SDImage(image: makeCGImage(), aspectRatio: 1, path: "")

        #expect(await sdi.exportPNGData() == nil)
    }

    @Test("Setting a Finder tag updates the gallery's copy")
    func finderTagUpdatesTheGallery() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        let gallery = ImageGallery()
        let controller = makeController(gallery: gallery)
        await controller.loadImages()
        let sdi = try #require(gallery.images.first)

        controller.setFinderTagColorNumber(sdi, colorNumber: 6)
        #expect(gallery.images.first?.finderTagColorNumber == 6)

        controller.clearFinderTags(try #require(gallery.images.first))
        #expect(gallery.images.first?.finderTagColorNumber == 0)
        controller.shutdown()
    }

    /// Cache consistency from the controller down. `removeImage` unlinks the file,
    /// so a later import can put different pixels at the same path, and both caches
    /// key on path.
    @Test("Deleting an image stops its pixels being served for that path")
    func deletingAnImageInvalidatesItsCaches() async throws {
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, "a cat"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: imageDir.appending(path: "one.png"),
            image: makeCGImage(width: 512, height: 256)
        )
        let thumbnailProvider = GalleryThumbnailProvider()
        let fullImageProvider = GalleryFullImageProvider()
        let gallery = ImageGallery()
        let controller = try await makeSettledController(
            gallery: gallery,
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
        let sdi = try #require(gallery.images.first)

        // Viewed: both caches now hold this file's pixels under its path.
        _ = try #require(await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        _ = try #require(await fullImageProvider.image(forPath: sdi.path))

        await controller.removeImage(sdi)
        // A different image is imported under the same name.
        let incoming = try temp.subdirectory("incoming").appending(path: "one.png")
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, "a dog"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: incoming,
            image: makeCGImage(width: 64, height: 256)
        )
        let imported = await controller.importImages(from: [incoming])
        #expect(imported.succeeded == 1)
        // The temporary folder is reached through a symlink, and loading and
        // importing spell its path differently.
        #expect(
            gallery.images.first.map { URL(filePath: $0.path).resolvingSymlinksInPath() }
                == URL(filePath: sdi.path).resolvingSymlinksInPath()
        )

        let thumbnail = try #require(
            await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        let full = try #require(await fullImageProvider.image(forPath: sdi.path))

        // The new image's shape, not the deleted one's 2:1.
        #expect(thumbnail.height == thumbnail.width * 4)
        #expect(full.width == 64)
        #expect(full.height == 256)
    }

    // MARK: - Folder sync

    @Test("Folder sync adds new files, drops deleted ones and keeps the rest")
    func syncReconcilesWithTheFolder() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        try writeImportableImage(named: "two.png", prompt: "a dog")
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)
        let kept = try #require(gallery.allImages.first { $0.prompt == "a cat" })

        try writeImportableImage(named: "three.png", prompt: "a bird")
        try FileManager.default.removeItem(at: imageDir.appending(path: "two.png"))
        await controller.syncImages()

        #expect(gallery.allImages.count == 2)
        #expect(Set(gallery.allImages.map(\.prompt)) == ["a cat", "a bird"])
        // The same record, not a reloaded copy, so its selection and state survive.
        #expect(gallery.allImages.first { $0.prompt == "a cat" }?.id == kept.id)
    }

    @Test("A second folder sync with no changes adds nothing")
    func repeatedSyncIsStable() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)
        try writeImportableImage(named: "two.png", prompt: "a dog")

        await controller.syncImages()
        await controller.syncImages()

        #expect(gallery.allImages.map(\.prompt).sorted() == ["a cat", "a dog"])
    }

    /// Covers a file removed outside the app, which `removeImage` never sees.
    @Test("Folder sync stops a vanished file's pixels being served for its path")
    func syncInvalidatesRemovedPaths() async throws {
        try writeImportableImage(
            named: "one.png", prompt: "a cat", image: makeCGImage(width: 512, height: 256))
        let thumbnailProvider = GalleryThumbnailProvider()
        let fullImageProvider = GalleryFullImageProvider()
        let gallery = ImageGallery()
        let controller = try await makeSettledController(
            gallery: gallery,
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
        let sdi = try #require(gallery.images.first)
        _ = try #require(await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        _ = try #require(await fullImageProvider.image(forPath: sdi.path))

        try FileManager.default.removeItem(atPath: sdi.path)
        await controller.syncImages()
        #expect(gallery.allImages.isEmpty)
        try writeImportableImage(
            named: "one.png", prompt: "a dog", image: makeCGImage(width: 64, height: 256))

        let thumbnail = try #require(
            await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        let full = try #require(await fullImageProvider.image(forPath: sdi.path))
        #expect(thumbnail.height == thumbnail.width * 4)
        #expect(full.width == 64)
    }

    // MARK: - Import

    @Test("Importing copies images into the images folder and adds them to the gallery")
    func importCopiesAndAdds() async throws {
        let incoming = try temp.subdirectory("incoming")
        try writeImportableImage(named: "valid.png", prompt: "imported", in: incoming)
        // No `Generator` key, so the version gate rejects it.
        try writePNG(caption: "Include in Image: raw", to: incoming.appending(path: "raw.png"))
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)

        let result = await controller.importImages(from: [
            incoming.appending(path: "valid.png"),
            incoming.appending(path: "raw.png"),
        ])

        #expect(result.succeeded == 1)
        #expect(result.failed == 1)
        let imported = try #require(gallery.allImages.only)
        #expect(imported.prompt == "imported")
        #expect(imported.path == imageDir.appending(path: "valid.png").path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: imported.path))
        #expect(!FileManager.default.fileExists(atPath: imageDir.appending(path: "raw.png").path))
        #expect(!controller.isLoading)
    }

    /// The folder monitor syncs shortly after the first imported file lands, so a
    /// long import overlaps a sync. The sync sees the copied files before the
    /// import has added them to the gallery.
    @Test("A folder sync during an import adds each imported image once")
    func importAndSyncTogetherAddEachImageOnce() async throws {
        let incoming = try temp.subdirectory("incoming")
        let urls = try (0..<20).map { index in
            try writeImportableImage(named: "\(index).png", prompt: "\(index)", in: incoming)
            return incoming.appending(path: "\(index).png")
        }
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)

        async let imported = controller.importImages(from: urls)
        async let synced: Void = controller.syncImages()
        _ = await (imported, synced)

        #expect(gallery.allImages.count == 20)
        #expect(Set(gallery.allImages.map(\.prompt)).count == 20)
    }

    // MARK: - One entry per file

    @Test("The gallery skips an image whose file it already holds")
    func galleryHoldsOneEntryPerFile() {
        let gallery = ImageGallery()
        let original = SDImage(
            image: nil, aspectRatio: 1, path: imageDir.appending(path: "one.png").path)
        // The same file reached through the resolved spelling of the folder.
        let again = SDImage(
            image: nil,
            aspectRatio: 1,
            path: imageDir.resolvingSymlinksInPath().appending(path: "one.png").path
        )

        let other = SDImage(
            image: nil, aspectRatio: 1, path: imageDir.appending(path: "two.png").path)
        let fields: Set<MetadataField> = [.prompt]

        let added = gallery.add(original)
        let skipped = gallery.add(again)
        let batch = gallery.add([
            (image: again, metadataFields: fields),
            (image: other, metadataFields: fields),
        ])

        #expect(added == original.id)
        #expect(skipped == nil)
        #expect(batch.count == 1)
        #expect(gallery.allImages.count == 2)
        #expect(gallery.allImages.first?.id == original.id)
    }

    @Test("Images with no file are always added")
    func imagesWithoutPathsAreAlwaysAdded() {
        let gallery = ImageGallery()

        gallery.add(SDImage())
        gallery.add(SDImage())

        #expect(gallery.allImages.count == 2)
    }

    // MARK: - Save All

    @Test("Save All writes every gallery image, numbered in gallery order")
    func saveAllWritesInGalleryOrder() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        try writeImportableImage(named: "two.png", prompt: "a dog")
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)
        let exportDir = try temp.subdirectory("export")

        await controller.saveAll(to: exportDir)

        let expected = gallery.images.enumerated().map { index, sdi in
            sdi.filenameWithoutExtension(count: index + 1) + ".png"
        }
        let written = try FileManager.default.contentsOfDirectory(
            atPath: exportDir.path(percentEncoded: false))
        #expect(written.sorted() == expected.sorted())
        for name in written {
            let data = try Data(contentsOf: exportDir.appending(path: name))
            #expect(pixelSize(of: data) != nil)
        }
    }

    /// An image that recorded only a prompt must not gain a scheduler and step
    /// count on the way out.
    @Test("Save All writes only the metadata fields each image recorded")
    func saveAllKeepsRecordedFields() async throws {
        try writeImportableImage(named: "one.png", prompt: "a cat")
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)
        let sdi = try #require(gallery.images.first)
        let exportDir = try temp.subdirectory("export")

        await controller.saveAll(to: exportDir)

        let name = sdi.filenameWithoutExtension(count: 1) + ".png"
        let exported = try #require(createImageRecordFromURL(exportDir.appending(path: name)))
        #expect(gallery.metadataFields(for: sdi.id) == [.prompt])
        #expect(exported.metadataFields == [.prompt])
        #expect(exported.prompt == "a cat")
    }

    @Test("Save All copies a generated PNG exactly and converts released JPEG and HEIC to PNG")
    func saveAllMixedFormats() async throws {
        let generated = MetadataRoundTripTests.coreMLMetadata(prompt: "a generated cat")
        try #require(await generated.pngData(for: makeCGImage()))
            .write(to: imageDir.appending(path: "generated.png"))
        for (name, type) in [("released.jpg", UTType.jpeg), ("released.heic", .heic)] {
            let data = CFDataCreateMutable(nil, 0)!
            let destination = try #require(
                CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
            let caption = releasedCaption([
                (.includeInImage, "a released \(type.preferredFilenameExtension!)"),
                (.seed, "42"),
                (.generator, "Mochi Diffusion 6.0"),
            ])
            let properties = [
                kCGImagePropertyIPTCDictionary: [
                    kCGImagePropertyIPTCCaptionAbstract: caption,
                    kCGImagePropertyIPTCOriginatingProgram: "Mochi Diffusion",
                    kCGImagePropertyIPTCProgramVersion: "6.0",
                ]
            ]
            CGImageDestinationAddImage(destination, makeCGImage(), properties as CFDictionary)
            try #require(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: imageDir.appending(path: name))
        }
        let gallery = ImageGallery()
        let controller = try await makeSettledController(gallery: gallery)
        let exportDir = try temp.subdirectory("export")
        try #require(gallery.images.count == 3)

        await controller.saveAll(to: exportDir)

        for (index, sdi) in gallery.images.enumerated() {
            let source = URL(fileURLWithPath: sdi.path)
            let exported = exportDir.appending(
                path: sdi.filenameWithoutExtension(count: index + 1) + ".png")
            let data = try Data(contentsOf: exported)
            let record = try #require(createImageRecordFromURL(exported))
            #expect(record.prompt == sdi.prompt)
            #expect(record.metadataFields == gallery.metadataFields(for: sdi.id))
            if source.pathExtension == "png" {
                #expect(data == (try Data(contentsOf: source)))
                #expect(record.startingImage == "starting.png")
                #expect(record.controlNetImage == "control.png")
            } else {
                #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
                #expect(record.seed == 42)
            }
        }
    }
}

extension Collection {
    /// The single element, or nil when there are none or several.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}

/// Filename and destination rules owned by `ImageRepository`.
@MainActor
struct ImageRepositoryTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func writeImportableImage(to url: URL, prompt: String = "a cat") throws {
        try writePNG(
            caption: releasedCaption([
                (.includeInImage, prompt),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: url
        )
    }

    @Test(
        "Loading recognizes supported extensions regardless of case",
        arguments: ["PNG", "JPG", "JPEG", "HEIC"]
    )
    func loadingAcceptsUppercaseExtensions(_ pathExtension: String) async throws {
        let directory = try temp.subdirectory("uppercase-\(pathExtension)")
        let source = directory.appending(path: "one.\(pathExtension)")
        try writeImportableImage(to: source)
        let repository = ImageRepository()

        let records = try await repository.load(
            imageDir: directory.path(percentEncoded: false)
        )

        #expect(records.count == 1)
        #expect(
            records.first.map { URL(filePath: $0.path).lastPathComponent }
                == source.lastPathComponent
        )
    }

    @Test("Prompt filenames contain content, never path components")
    func promptFilenamesAreSanitized() {
        #expect(
            imageFilenameWithoutExtension(
                prompt: "../../folder/cat: portrait?",
                seed: 42,
                count: 3
            ) == "folder cat portrait.3.42"
        )
        #expect(
            imageFilenameWithoutExtension(
                prompt: "a\n\tcat   portrait",
                seed: 9
            ) == "a cat portrait.9"
        )
        #expect(
            imageFilenameWithoutExtension(
                prompt: " ._-/// ",
                seed: 7
            ) == "Image.7"
        )
    }

    @Test("Prompt filename bases are capped at seventy characters")
    func promptFilenameBaseIsCapped() throws {
        let base = try #require(
            sanitizedImageFilenameBase(from: String(repeating: "a", count: 100))
        )

        #expect(base.count == 70)
    }

    @Test("SDImage uses the shared sanitized filename rules")
    func sdImageUsesSharedFilenameRules() {
        var image = SDImage()
        image.prompt = "../a/cat?"
        image.seed = 11

        #expect(image.filenameWithoutExtension() == "a cat.11")
        #expect(image.filenameWithoutExtension(count: 4) == "a cat.4.11")
    }

    @Test("Writing the same name twice preserves the first file")
    func duplicateWritesChooseAvailablePaths() async throws {
        let directory = try temp.subdirectory("images")
        let repository = ImageRepository()

        let first = try #require(
            await repository.writeImage(
                filenameWithoutExtension: "A cat.1.42",
                imageData: Data([1]),
                imageDir: directory.path(percentEncoded: false)
            )
        )
        let second = try #require(
            await repository.writeImage(
                filenameWithoutExtension: "A cat.1.42",
                imageData: Data([2]),
                imageDir: directory.path(percentEncoded: false)
            )
        )

        #expect(first.lastPathComponent == "A cat.1.42.png")
        #expect(second.lastPathComponent == "A cat.1.42-2.png")
        #expect(try Data(contentsOf: first) == Data([1]))
        #expect(try Data(contentsOf: second) == Data([2]))
    }

    @Test("Concurrent writes receive distinct paths")
    func concurrentWritesAreSerialized() async throws {
        let directory = try temp.subdirectory("concurrent-images")
        let repository = ImageRepository()

        let urls = await withTaskGroup(of: URL?.self) { group in
            for byte in UInt8(0)..<8 {
                group.addTask {
                    await repository.writeImage(
                        filenameWithoutExtension: "same-name",
                        imageData: Data([byte]),
                        imageDir: directory.path(percentEncoded: false)
                    )
                }
            }

            var urls: [URL] = []
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
            return urls
        }

        #expect(urls.count == 8)
        #expect(Set(urls).count == 8)
    }

    @Test("Repository filenames cannot escape their destination")
    func repositoryAcceptsOnlyFilenameComponents() async throws {
        let directory = try temp.subdirectory("safe-images")
        let repository = ImageRepository()

        let url = try #require(
            await repository.writeImage(
                filenameWithoutExtension: "../../outside",
                imageData: Data([1]),
                imageDir: directory.path(percentEncoded: false)
            )
        )

        #expect(url.deletingLastPathComponent() == directory)
        #expect(url.lastPathComponent == "outside.png")
    }

    @Test("A folder that cannot be created for a non-permission reason names the cause")
    func nonPermissionDirectoryFailureKeepsCause() async throws {
        let blocker = temp.appending("not-a-folder")
        try Data([1]).write(to: blocker)
        let directory = blocker.appending(path: "images")
        let repository = ImageRepository()

        do {
            _ = try await repository.ensureOutputDirectory(
                imageDir: directory.path(percentEncoded: false)
            )
            Issue.record("Expected creating the images folder to fail")
        } catch ImageRepositoryError.imageDirectoryUnavailable(let path, let reason) {
            #expect(URL(fileURLWithPath: path).pathComponents == directory.pathComponents)
            #expect(!reason.isEmpty)
        }
    }

    @Test("A folder Mochi may not create is reported as no access")
    func permissionDirectoryFailureIsNoAccess() async throws {
        let parent = try temp.subdirectory("read-only")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: parent.path
            )
        }
        let directory = parent.appending(path: "images")
        let repository = ImageRepository()

        do {
            _ = try await repository.ensureOutputDirectory(
                imageDir: directory.path(percentEncoded: false)
            )
            Issue.record("Expected creating the images folder to fail")
        } catch ImageRepositoryError.imageDirectoryNoAccess(let path) {
            #expect(URL(fileURLWithPath: path).pathComponents == directory.pathComponents)
        }
    }

    @Test("An empty image directory resolves to the injected default")
    func emptyDirectoryUsesDefaultForWrites() async throws {
        let defaultDirectory = temp.appending("default-images")
        let repository = ImageRepository(defaultImageDirectoryURL: defaultDirectory)
        _ = try await repository.ensureOutputDirectory(imageDir: "")

        let url = try #require(
            await repository.writeImage(
                filenameWithoutExtension: "default-location",
                imageData: Data([1]),
                imageDir: ""
            )
        )

        #expect(url.deletingLastPathComponent().pathComponents == defaultDirectory.pathComponents)
    }

    @Test("Import uses the same default directory as gallery loading")
    func importUsesDefaultDirectory() async throws {
        let incomingDirectory = try temp.subdirectory("incoming")
        let source = incomingDirectory.appending(path: "one.png")
        try writeImportableImage(to: source)
        let defaultDirectory = temp.appending("default-imports")
        let repository = ImageRepository(defaultImageDirectoryURL: defaultDirectory)

        let (records, failed) = await repository.importImages(from: [source], imageDir: "")

        #expect(failed == 0)
        #expect(records.count == 1)
        #expect(records.first?.path == defaultDirectory.appending(path: "one.png").path)
    }

    @Test("An uppercase import remains visible after reload")
    func uppercaseImportSurvivesReload() async throws {
        let incomingDirectory = try temp.subdirectory("uppercase-incoming")
        let supportedSource = incomingDirectory.appending(path: "supported.PNG")
        let unsupportedSource = incomingDirectory.appending(path: "unsupported.TIFF")
        try writeImportableImage(to: supportedSource, prompt: "supported")
        try writeImportableImage(to: unsupportedSource, prompt: "unsupported")
        let destination = try temp.subdirectory("uppercase-destination")
        let unsupportedDestination = destination.appending(path: "unsupported.TIFF")
        let repository = ImageRepository()

        let (imported, failed) = await repository.importImages(
            from: [supportedSource, unsupportedSource],
            imageDir: destination.path(percentEncoded: false)
        )
        let reloaded = try await repository.load(
            imageDir: destination.path(percentEncoded: false)
        )

        #expect(imported.count == 1)
        #expect(imported.first?.prompt == "supported")
        #expect(failed == 1)
        #expect(reloaded.count == 1)
        #expect(reloaded.first.map { URL(filePath: $0.path).lastPathComponent } == "supported.PNG")
        #expect(!FileManager.default.fileExists(atPath: unsupportedDestination.path))
    }

    @Test("Folder sync accepts uppercase extensions without adding new formats")
    func syncUsesSupportedExtensionsCaseInsensitively() async throws {
        let directory = try temp.subdirectory("uppercase-sync")
        try writeImportableImage(to: directory.appending(path: "supported.HEIC"))
        try writeImportableImage(to: directory.appending(path: "unsupported.TIFF"))
        let repository = ImageRepository()

        let result = await repository.syncImages(
            imageDir: directory.path(percentEncoded: false),
            existingPaths: []
        )

        #expect(result.additions.count == 1)
        #expect(result.additions.first?.path.hasSuffix("supported.HEIC") == true)
        #expect(result.removals.isEmpty)
    }

    @Test("Invalid imports leave no copy in the image directory")
    func invalidImportsAreNotCopied() async throws {
        let incomingDirectory = try temp.subdirectory("invalid-incoming")
        let source = incomingDirectory.appending(path: "invalid.png")
        try writePNG(caption: "Include in Image: a cat", to: source)
        let destination = try temp.subdirectory("invalid-destination")
        let invalidDestination = destination.appending(path: "invalid.png")
        let repository = ImageRepository()

        let (records, failed) = await repository.importImages(
            from: [source],
            imageDir: destination.path(percentEncoded: false)
        )

        #expect(records.isEmpty)
        #expect(failed == 1)
        #expect(!FileManager.default.fileExists(atPath: invalidDestination.path))
    }

    @Test("Mixed imports preserve collisions and report accurate counts")
    func mixedImportsPreserveExistingFiles() async throws {
        let incomingDirectory = try temp.subdirectory("mixed-incoming")
        let validSource = incomingDirectory.appending(path: "valid.png")
        let invalidSource = incomingDirectory.appending(path: "invalid.png")
        let collisionSource = incomingDirectory.appending(path: "collision.png")
        try writeImportableImage(to: validSource, prompt: "valid")
        try writePNG(caption: "Include in Image: invalid", to: invalidSource)
        try writeImportableImage(to: collisionSource, prompt: "replacement")

        let destination = try temp.subdirectory("mixed-destination")
        let validDestination = destination.appending(path: "valid.png")
        let invalidDestination = destination.appending(path: "invalid.png")
        let existingURL = destination.appending(path: "collision.png")
        let existingData = Data([1, 2, 3])
        try existingData.write(to: existingURL)
        let repository = ImageRepository()

        let (records, failed) = await repository.importImages(
            from: [validSource, invalidSource, collisionSource],
            imageDir: destination.path(percentEncoded: false)
        )

        #expect(records.count == 1)
        #expect(records.first?.prompt == "valid")
        #expect(failed == 2)
        #expect(FileManager.default.fileExists(atPath: validDestination.path))
        #expect(!FileManager.default.fileExists(atPath: invalidDestination.path))
        #expect(try Data(contentsOf: existingURL) == existingData)
    }

    @Test("Save All does not replace an existing export")
    func exportChoosesAvailablePath() async throws {
        let directory = try temp.subdirectory("exports")
        let original = directory.appending(path: "A cat.1.42.png")
        try Data([1]).write(to: original)
        let repository = ImageRepository()

        await repository.exportAllImages(
            [
                ImageExportRequest(
                    filenameWithoutExtension: "A cat.1.42",
                    imageData: Data([2])
                )
            ],
            to: directory
        )

        #expect(try Data(contentsOf: original) == Data([1]))
        #expect(try Data(contentsOf: directory.appending(path: "A cat.1.42-2.png")) == Data([2]))
    }
}
