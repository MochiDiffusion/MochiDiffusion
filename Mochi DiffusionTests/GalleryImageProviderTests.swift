//
//  GalleryImageProviderTests.swift
//  Mochi DiffusionTests
//

import CoreGraphics
import Foundation
import Testing

@testable import Mochi_Diffusion

/// The providers the gallery renders from, now that it no longer holds a decoded
/// full-size image per entry.
struct GalleryImageProviderTests {
    let temp: TempDirectory

    init() throws {
        temp = try TempDirectory()
    }

    private func writeImage(_ name: String, width: Int, height: Int) throws -> String {
        let url = temp.appending(name)
        try writePNG(caption: "", to: url, image: makeCGImage(width: width, height: height))
        return url.path(percentEncoded: false)
    }

    @Test("A thumbnail is bounded by the size asked for, keeping its aspect ratio")
    func thumbnailIsDownsampled() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        let thumbnail = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))

        #expect(max(thumbnail.width, thumbnail.height) <= 64)
        // 2:1 in, 2:1 out.
        #expect(thumbnail.width == thumbnail.height * 2)
    }

    /// Keyed by path *and* size, so the same file at two sizes is two entries rather
    /// than one being reused at the wrong resolution.
    @Test("Different sizes are different entries")
    func sizeIsPartOfTheKey() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        let small = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))
        let large = try #require(await provider.thumbnail(for: path, maxPixelSize: 256))

        #expect(max(small.width, small.height) <= 64)
        #expect(max(large.width, large.height) <= 256)
        #expect(large.width > small.width)
    }

    @Test("A second ask for the same thumbnail returns the cached one")
    func repeatedAsksAreCached() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        let first = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))
        let second = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))

        // The same object, not merely an equivalent one. That is what "cached" has to
        // mean here, and it is what keeps scrolling from decoding repeatedly.
        #expect(first === second)
    }

    /// Scrolling produces a burst of identical requests. Without coalescing, each
    /// would decode its own copy of the same file.
    @Test("Concurrent asks for the same thumbnail decode once")
    func concurrentAsksAreCoalesced() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        let images = await withTaskGroup(of: CGImage?.self) { group in
            for _ in 0..<8 {
                group.addTask { await provider.thumbnail(for: path, maxPixelSize: 64) }
            }
            var results: [CGImage?] = []
            for await image in group {
                results.append(image)
            }
            return results
        }

        let unwrapped = images.compactMap { $0 }
        #expect(unwrapped.count == 8)
        // One decode shared by all eight, whether they joined the in-flight task or
        // hit the cache it populated.
        #expect(unwrapped.allSatisfy { $0 === unwrapped[0] })
    }

    @Test("A missing file and an empty path produce nothing")
    func badInputsProduceNothing() async throws {
        let provider = GalleryThumbnailProvider()
        let missing = temp.appending("absent.png").path(percentEncoded: false)

        #expect(await provider.thumbnail(for: "", maxPixelSize: 64) == nil)
        #expect(await provider.thumbnail(for: missing, maxPixelSize: 64) == nil)
    }

    /// A cell laid out before SwiftUI has given it a size asks for zero, which must
    /// not be treated as "as small as possible".
    @Test("A zero size produces nothing")
    func zeroSizeProducesNothing() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        #expect(await provider.thumbnail(for: path, maxPixelSize: 0) == nil)
    }

    @Test("Invalidating drops what was cached")
    func invalidateClearsTheCache() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()
        let first = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))

        await provider.invalidate()
        let second = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))

        #expect(first !== second)
    }

    @Test("The full-image provider prefers pixels already in hand")
    func fullImagePrefersResidentPixels() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let resident = makeCGImage(width: 8, height: 8)
        var sdi = SDImage(image: resident, aspectRatio: 1, path: path)
        sdi.width = 8
        sdi.height = 8
        let provider = GalleryFullImageProvider()

        let image = try #require(await provider.image(for: sdi))

        // The resident one, not a fresh read of the much larger file.
        #expect(image === resident)
    }

    @Test("The full-image provider reads the file when nothing is resident")
    func fullImageReadsFromDisk() async throws {
        let path = try writeImage("big.png", width: 512, height: 256)
        let sdi = SDImage(image: nil, aspectRatio: 2, path: path)
        let provider = GalleryFullImageProvider()

        let image = try #require(await provider.image(for: sdi))

        #expect(image.width == 512)
        #expect(image.height == 256)
    }

    // MARK: - The synchronous cache peek

    /// What a rebuilt `LazyVGrid` cell relies on: its `@State` thumbnail is gone, and
    /// an `await` to fetch a resident image is long enough to paint a spinner.
    @Test("A cached thumbnail can be read without suspending")
    func cachedThumbnailIsAvailableSynchronously() async throws {
        let path = try writeImage("recycled.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        // Nothing loaded yet, so nothing to hand back.
        #expect(provider.cachedThumbnail(for: path, maxPixelSize: 64) == nil)

        let loaded = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))
        let peeked = try #require(provider.cachedThumbnail(for: path, maxPixelSize: 64))

        // The same object the async path returned, not a second decode.
        #expect(peeked === loaded)
    }

    @Test("The peek is keyed by size, like the cache it reads")
    func cachedThumbnailIsSizeSpecific() async throws {
        let path = try writeImage("sized.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        _ = await provider.thumbnail(for: path, maxPixelSize: 64)

        #expect(provider.cachedThumbnail(for: path, maxPixelSize: 64) != nil)
        // A resize that crosses a bucket is a miss, and must load rather than
        // hand back an image at the wrong resolution.
        #expect(provider.cachedThumbnail(for: path, maxPixelSize: 128) == nil)
    }

    @Test(
        "A peek with nothing to look up is a miss",
        arguments: [("", 64), ("/nonexistent/image.png", 64), ("/tmp/image.png", 0)]
    )
    func cachedThumbnailRejectsEmptyLookups(path: String, maxPixelSize: Int) {
        let provider = GalleryThumbnailProvider()

        #expect(provider.cachedThumbnail(for: path, maxPixelSize: maxPixelSize) == nil)
    }

    @Test("Invalidating clears what the peek can see")
    func invalidateClearsThePeek() async throws {
        let path = try writeImage("dropped.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()

        _ = await provider.thumbnail(for: path, maxPixelSize: 64)
        #expect(provider.cachedThumbnail(for: path, maxPixelSize: 64) != nil)

        await provider.invalidate()

        #expect(provider.cachedThumbnail(for: path, maxPixelSize: 64) == nil)
    }
}
