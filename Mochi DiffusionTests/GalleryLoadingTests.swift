//
//  GalleryLoadingTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing
import UniformTypeIdentifiers

@testable import Mochi_Diffusion

/// Gallery loading, into a gallery this suite owns.
///
/// Not possible before `GalleryController` took an injected `ImageGallery`:
/// `loadImages()` calls `replaceAll`, which against `ImageGallery.shared` would
/// have replaced the contents of the gallery the app is showing — and would have
/// raced any other suite doing the same.
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
            focusController: FocusController(),
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
    }

    /// Writes an importable image: the version gate rejects anything without a
    /// `Generator` key naming 2.2 or later.
    private func writeImportableImage(named name: String, prompt: String) throws {
        try writePNG(
            caption: MetadataCodec.encode([
                (.includeInImage, prompt),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: imageDir.appending(path: name)
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

    /// The reason the injection was worth doing: two controllers loading at once
    /// touch only their own gallery.
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

    /// The point of the whole exercise: a gallery image is not decoded at load.
    ///
    /// A decoded 1024x1024 image is about 4 MB, so holding one per entry made a large
    /// gallery cost gigabytes for pictures drawn a couple of hundred points wide.
    @Test("A loaded image carries no decoded pixels, but knows its size")
    func loadedImagesAreNotDecoded() async throws {
        try writePNG(
            caption: MetadataCodec.encode([
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
            caption: MetadataCodec.encode([
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

    /// Save As, Save All and Copy all go through `imageData`, and would each have
    /// silently produced nothing once gallery images stopped being decoded.
    @Test("Re-encoding loads the file when no pixels are resident")
    func imageDataLoadsFromDisk() async throws {
        let url = imageDir.appending(path: "one.png")
        try writePNG(
            caption: MetadataCodec.encode([
                (.includeInImage, "a cat"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: url,
            image: makeCGImage(width: 64, height: 32)
        )
        var sdi = SDImage(image: nil, aspectRatio: 2, path: url.path(percentEncoded: false))
        sdi.width = 64
        sdi.height = 32

        let data = try #require(await sdi.imageData(.png, metadataFields: [.prompt]))

        #expect(pixelSize(of: data) == CGSize(width: 64, height: 32))
    }

    @Test("An image with neither pixels nor a path re-encodes to nothing")
    func imageDataWithoutSourceIsNil() async {
        let sdi = SDImage(image: nil, aspectRatio: 0, path: "")

        #expect(await sdi.imageData(.png) == nil)
    }

    /// The half of Finder tagging that needed a gallery to talk to, which is why it
    /// moved off a free function and onto the controller.
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

    /// The user-facing half of the cache-consistency defect, from the controller
    /// down.
    ///
    /// Deleting an image and putting different pixels at the same path is
    /// reachable without leaving the app: `removeImage` unlinks the file, and an
    /// import then succeeds where it would otherwise have refused to overwrite.
    /// Both caches key on path, so without invalidation the grid drew the deleted
    /// image under the new one's name — and `GalleryFullImageProvider` handed the
    /// same stale pixels to export and to generation input.
    ///
    /// The import itself is behind an `NSOpenPanel`, so this drives the delete and
    /// writes the replacement directly, which is the same sequence of effects on
    /// the folder.
    @Test("Deleting an image stops its pixels being served for that path")
    func deletingAnImageInvalidatesItsCaches() async throws {
        try writePNG(
            caption: MetadataCodec.encode([
                (.includeInImage, "a cat"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: imageDir.appending(path: "one.png"),
            image: makeCGImage(width: 512, height: 256)
        )
        let thumbnailProvider = GalleryThumbnailProvider()
        let fullImageProvider = GalleryFullImageProvider()
        let gallery = ImageGallery()
        let controller = makeController(
            gallery: gallery,
            thumbnailProvider: thumbnailProvider,
            fullImageProvider: fullImageProvider
        )
        await controller.loadImages()
        let sdi = try #require(gallery.images.first)

        // Viewed: both caches now hold this file's pixels under its path.
        _ = try #require(await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        _ = try #require(await fullImageProvider.image(forPath: sdi.path))

        await controller.removeImage(sdi)
        // A different image arrives at the same path, as a reimport produces.
        try writePNG(
            caption: MetadataCodec.encode([
                (.includeInImage, "a dog"),
                (.generator, "Mochi Diffusion 6.0"),
            ]),
            to: URL(filePath: sdi.path),
            image: makeCGImage(width: 64, height: 256)
        )

        let thumbnail = try #require(
            await thumbnailProvider.thumbnail(for: sdi.path, maxPixelSize: 64))
        let full = try #require(await fullImageProvider.image(forPath: sdi.path))

        // The new image's shape, not the deleted one's 2:1.
        #expect(thumbnail.height == thumbnail.width * 4)
        #expect(full.width == 64)
        #expect(full.height == 256)
        controller.shutdown()
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
            caption: MetadataCodec.encode([
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
                imageDir: directory.path(percentEncoded: false),
                imageType: "png"
            )
        )
        let second = try #require(
            await repository.writeImage(
                filenameWithoutExtension: "A cat.1.42",
                imageData: Data([2]),
                imageDir: directory.path(percentEncoded: false),
                imageType: "png"
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
                        imageDir: directory.path(percentEncoded: false),
                        imageType: "png"
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
                imageDir: directory.path(percentEncoded: false),
                imageType: "png"
            )
        )

        #expect(url.deletingLastPathComponent() == directory)
        #expect(url.lastPathComponent == "outside.png")
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
                imageDir: "",
                imageType: "png"
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
            to: directory,
            type: .png
        )

        #expect(try Data(contentsOf: original) == Data([1]))
        #expect(try Data(contentsOf: directory.appending(path: "A cat.1.42-2.png")) == Data([2]))
    }
}
