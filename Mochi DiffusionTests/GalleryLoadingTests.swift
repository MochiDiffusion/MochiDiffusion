//
//  GalleryLoadingTests.swift
//  Mochi DiffusionTests
//

import Foundation
import Testing

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

    private func makeController(gallery: ImageGallery) -> GalleryController {
        let configStore = ConfigStore(store: defaults.defaults)
        configStore.imageDir = imageDir.path(percentEncoded: false)
        return GalleryController(
            configStore: configStore,
            imageGallery: gallery,
            focusController: FocusController()
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
}
