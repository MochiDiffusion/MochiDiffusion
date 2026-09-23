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

    // MARK: - Keeping cached pixels consistent with the file

    /// The defect these tests exist for. Both caches key on path, and a path can
    /// be reused without leaving the app: delete an image, import a different one
    /// under the same name, and every later read — the grid, Quick Look, export,
    /// and generation input — was served the deleted image's pixels.
    @Test("A path invalidated once no longer serves the old pixels")
    func invalidatingAPathDropsItsThumbnail() async throws {
        let path = try writeImage("reused.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()
        _ = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))

        // Different contents at the same path, as a delete and a reimport produce.
        try writePNG(
            caption: "", to: URL(filePath: path), image: makeCGImage(width: 64, height: 256))
        provider.invalidate(path: path)

        let reloaded = try #require(await provider.thumbnail(for: path, maxPixelSize: 64))
        // 1:4 now, where the cached one was 2:1.
        #expect(reloaded.height == reloaded.width * 4)
    }

    /// Invalidation has to reach every size the path was cached at. The grid holds
    /// a path at several buckets at once while a window is being resized, so
    /// clearing one and leaving the rest would show the old image at the next
    /// size the cell settles on.
    @Test("Invalidating a path reaches every size it was cached at")
    func invalidatingAPathReachesEverySize() async throws {
        let path = try writeImage("reused.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()
        _ = await provider.thumbnail(for: path, maxPixelSize: 64)
        _ = await provider.thumbnail(for: path, maxPixelSize: 128)
        _ = await provider.thumbnail(for: path, maxPixelSize: 256)

        provider.invalidate(path: path)

        for size in [64, 128, 256] {
            #expect(provider.cachedThumbnail(for: path, maxPixelSize: size) == nil)
        }
    }

    /// Targeted, so deleting one image does not throw away the decoded thumbnails
    /// of everything else on screen.
    @Test("Invalidating one path leaves the others cached")
    func invalidatingAPathSparesOtherPaths() async throws {
        let changed = try writeImage("changed.png", width: 512, height: 256)
        let untouched = try writeImage("untouched.png", width: 512, height: 256)
        let provider = GalleryThumbnailProvider()
        _ = await provider.thumbnail(for: changed, maxPixelSize: 64)
        let keep = try #require(await provider.thumbnail(for: untouched, maxPixelSize: 64))

        provider.invalidate(path: changed)

        #expect(provider.cachedThumbnail(for: changed, maxPixelSize: 64) == nil)
        #expect(provider.cachedThumbnail(for: untouched, maxPixelSize: 64) === keep)
    }

    @Test("The full-image provider stops serving an invalidated path")
    func invalidatingAPathDropsTheFullImage() async throws {
        let path = try writeImage("reused.png", width: 512, height: 256)
        let provider = GalleryFullImageProvider()
        let first = try #require(await provider.image(forPath: path))
        #expect(first.width == 512)

        try writePNG(
            caption: "", to: URL(filePath: path), image: makeCGImage(width: 64, height: 64))
        provider.invalidate(path: path)

        let reloaded = try #require(await provider.image(forPath: path))
        #expect(reloaded.width == 64)
    }

    /// The second half of the defect, and the one a targeted invalidation does not
    /// fix by itself: a read that was already running when the file changed
    /// resumes holding the old pixels and used to write them straight back into
    /// the cache, undoing the invalidation that happened while it was suspended.
    ///
    /// Driven through the full-image provider because its loader is injectable, so
    /// the overlap is arranged rather than raced. The thumbnail provider resolves
    /// it the same way — the generation is part of the key in both.
    @Test("A load in flight when a path changes cannot repopulate the cache")
    func inFlightLoadCannotRestoreStalePixels() async throws {
        let path = try writeImage("reused.png", width: 512, height: 256)
        let started = AsyncSemaphore()
        let release = AsyncSemaphore()
        let stale = makeCGImage(width: 512, height: 256)
        let fresh = makeCGImage(width: 64, height: 64)
        let loads = Counter()

        let provider = GalleryFullImageProvider { _ in
            loads.increment()
            // The first load is the one that overlaps the change; later loads
            // must see the new file rather than replay the old answer.
            if loads.value == 1 {
                await started.signal()
                await release.wait()
                return stale
            }
            return fresh
        }

        let inFlight = Task { await provider.image(forPath: path) }
        await started.wait()

        // The file changes, and the gallery says so, while that load is suspended.
        provider.invalidate(path: path)
        await release.signal()
        #expect(await inFlight.value === stale)

        // The stale pixels were returned to the caller that asked before the
        // change — which is unavoidable — but must not be what the cache now holds.
        let after = try #require(await provider.image(forPath: path))
        #expect(after === fresh)
    }
}

/// A one-shot signal usable from either side of an `await`.
///
/// `CheckedContinuation` rather than a poll, so the overlap in
/// `inFlightLoadCannotRestoreStalePixels` is arranged exactly rather than slept
/// into place.
private actor AsyncSemaphore {
    private var isSignalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignalled = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func wait() async {
        if isSignalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// A counter readable from the `@Sendable` loader closure without an actor hop.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
