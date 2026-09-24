//
//  GalleryImageProviders.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Which version of a file's contents a cache entry was made from.
///
/// `NSCache` cannot enumerate its keys, and a thumbnail path is cached at up to
/// thirty size buckets at once, so dropping one path's entries by deleting them
/// would mean maintaining a side index of every key — and keeping that index
/// correct through evictions the cache makes silently. Folding a generation into
/// the key instead makes invalidation O(1) and needs no index: the superseded
/// entries simply become unreachable and fall out under the cache's own count
/// limit.
///
/// It is also what makes a load that is already in flight harmless. Such a load
/// resumes holding pixels read before the file changed, and its key names the
/// generation it started in, so it cannot put them anywhere a later read will
/// look.
///
/// Lock-guarded rather than actor-isolated because
/// `GalleryThumbnailProvider.cachedThumbnail(for:maxPixelSize:)` is synchronous
/// and needs a token during layout — avoiding that actor hop is the whole reason
/// that call exists.
nonisolated final class GalleryCacheGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var all = 0
    private var byPath: [String: Int] = [:]

    /// Identifies the current contents of `path`.
    func token(for path: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return "\(all).\(byPath[path] ?? 0)"
    }

    /// Supersedes every entry cached for `path`.
    ///
    /// Only paths that have actually changed are recorded, so this grows with the
    /// images a session deletes or imports rather than with the images it caches.
    func bump(_ path: String) {
        lock.lock()
        byPath[path, default: 0] += 1
        lock.unlock()
    }

    /// Supersedes everything. Clearing the per-path entries is safe because the
    /// shared counter has already moved, so every token they could produce differs
    /// from every token issued before.
    func bumpAll() {
        lock.lock()
        all += 1
        byPath.removeAll()
        lock.unlock()
    }
}

/// Downsampled thumbnails for the gallery grid, read from disk rather than from a
/// decoded image in memory.
///
/// A decoded 1024x1024 image is about 4 MB, so gallery entries do not hold
/// full-size pixels. The `NSCache` lets the system evict under pressure, and
/// `inFlightRequests` coalesces concurrent asks for the same path and size, since
/// scrolling produces bursts of identical requests.
actor GalleryThumbnailProvider {
    /// `NSCache` needs a class, and `CGImage` is not one.
    ///
    /// Immutable, and `CGImage` is itself `Sendable`, so instances cross isolation
    /// domains safely.
    private final class CachedThumbnail: @unchecked Sendable {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    /// `nonisolated(unsafe)` because `NSCache` does its own locking, which is what
    /// the project's `@unchecked Sendable` policy requires: the type guards its own
    /// mutable state rather than relying on callers being serialized. That lets
    /// `cachedThumbnail(for:maxPixelSize:)` read it without an actor hop.
    nonisolated(unsafe) private let cache = NSCache<NSString, CachedThumbnail>()
    private var inFlightRequests: [String: Task<CGImage?, Never>] = [:]
    /// Which contents each cached entry was made from. See `GalleryCacheGenerations`.
    private let generations = GalleryCacheGenerations()

    init(countLimit: Int = 256) {
        cache.countLimit = countLimit
    }

    func thumbnail(for path: String, maxPixelSize: Int) async -> CGImage? {
        guard !path.isEmpty, maxPixelSize > 0 else { return nil }

        let cacheKey = cacheKey(for: path, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        if let request = inFlightRequests[cacheKey] {
            return await request.value
        }

        let request = Task(priority: .utility) {
            Self.makeThumbnail(for: path, maxPixelSize: maxPixelSize)
        }
        inFlightRequests[cacheKey] = request

        let image = await request.value
        inFlightRequests[cacheKey] = nil

        // The actor suspends at the await above, so the file may have changed
        // while this load was running — in which case these pixels are the old
        // ones and `cacheKey` names a generation nothing will ask for again.
        // Re-deriving the key is how that is detected; skipping the write keeps a
        // dead entry from occupying a slot until it is evicted.
        if let image, cacheKey == self.cacheKey(for: path, maxPixelSize: maxPixelSize) {
            cache.setObject(CachedThumbnail(image), forKey: cacheKey as NSString)
        }

        return image
    }

    /// What is already cached, read synchronously.
    ///
    /// A `LazyVGrid` cell scrolled or resized out of the render window is rebuilt
    /// with fresh `@State`, losing its thumbnail. Going through the actor costs an
    /// `await` long enough to paint a `ProgressView`, so this lets a rebuilt cell
    /// draw a cached image in the same layout pass.
    ///
    /// Returns nil on a miss; the caller then loads through `thumbnail(for:maxPixelSize:)`.
    nonisolated func cachedThumbnail(for path: String, maxPixelSize: Int) -> CGImage? {
        guard !path.isEmpty, maxPixelSize > 0 else { return nil }
        let key = cacheKey(for: path, maxPixelSize: maxPixelSize)
        return cache.object(forKey: key as NSString)?.image
    }

    /// Drops what is cached for one path, for a file that changed or went away.
    ///
    /// Size-agnostic, because the cache is keyed by path *and* size and clearing a
    /// single entry would leave the others stale. Supersedes rather than deletes —
    /// see `GalleryCacheGenerations` for why that is the cheaper way to reach every
    /// size at once.
    ///
    /// `nonisolated`, so the gallery can invalidate at the moment it changes a file
    /// rather than hopping onto this actor to do it.
    nonisolated func invalidate(path: String) {
        guard !path.isEmpty else { return }
        generations.bump(path)
    }

    /// Drops everything, for when the gallery is no longer looking at the same
    /// folder. Unlike the per-path form this also frees the entries, since none of
    /// them can be wanted again.
    func invalidate() {
        generations.bumpAll()
        cache.removeAllObjects()
    }

    nonisolated private func cacheKey(for path: String, maxPixelSize: Int) -> String {
        "\(path)#\(maxPixelSize)#\(generations.token(for: path))"
    }

    /// `kCGImageSourceShouldCache: false` matters as much as the max pixel size:
    /// without it ImageIO keeps the decoded full-size image around, which is the
    /// cost this type exists to avoid.
    nonisolated private static func makeThumbnail(for path: String, maxPixelSize: Int) -> CGImage? {
        let url = URL(fileURLWithPath: path, isDirectory: false)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let imageIndex = CGImageSourceGetPrimaryImageIndex(source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, imageIndex, options as CFDictionary)
    }
}

/// Full-size images, on demand, for the few things that need real pixels: Quick
/// Look, sharing, saving and copying.
///
/// A much smaller cache than the thumbnail one, because these are the expensive
/// objects. `image(for:)` returns an already-resident image when there is one — a
/// freshly generated picture arrives with its pixels in hand, and re-reading it from
/// disk to show it would be a pointless round trip.
actor GalleryFullImageProvider {
    private final class CachedImage {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CachedImage>()
    private var inFlightRequests: [String: Task<CGImage?, Never>] = [:]
    private let imageLoader: @Sendable (String) async -> CGImage?
    /// Which contents each cached entry was made from. See `GalleryCacheGenerations`.
    private let generations = GalleryCacheGenerations()

    init(
        countLimit: Int = 32,
        imageLoader: @escaping @Sendable (String) async -> CGImage? = { path in
            cgImageFromFileURL(URL(fileURLWithPath: path, isDirectory: false))
        }
    ) {
        cache.countLimit = countLimit
        self.imageLoader = imageLoader
    }

    func image(for sdi: SDImage) async -> CGImage? {
        if let image = sdi.image {
            return image
        }
        return await image(forPath: sdi.path)
    }

    func image(forPath path: String) async -> CGImage? {
        guard !path.isEmpty else { return nil }

        let cacheKey = cacheKey(for: path)
        if let cached = cache.object(forKey: cacheKey as NSString) {
            return cached.image
        }

        if let request = inFlightRequests[cacheKey] {
            return await request.value
        }

        let imageLoader = imageLoader
        let request = Task(priority: .utility) {
            await imageLoader(path)
        }
        inFlightRequests[cacheKey] = request

        let image = await request.value
        inFlightRequests[cacheKey] = nil

        // As in `GalleryThumbnailProvider.thumbnail(for:maxPixelSize:)`: pixels
        // read before the file changed must not be written back under a key a
        // later read would find. It matters more here, since these images are fed
        // to generation and to export, not only drawn.
        if let image, cacheKey == self.cacheKey(for: path) {
            cache.setObject(CachedImage(image), forKey: cacheKey as NSString)
        }

        return image
    }

    /// Drops what is cached for one path. `nonisolated` for the same reason as the
    /// thumbnail provider's.
    nonisolated func invalidate(path: String) {
        guard !path.isEmpty else { return }
        generations.bump(path)
    }

    func invalidate() {
        generations.bumpAll()
        cache.removeAllObjects()
    }

    private func cacheKey(for path: String) -> String {
        "\(path)#\(generations.token(for: path))"
    }
}

// MARK: - Environment

private struct GalleryThumbnailProviderKey: EnvironmentKey {
    static let defaultValue = GalleryThumbnailProvider()
}

private struct GalleryFullImageProviderKey: EnvironmentKey {
    static let defaultValue = GalleryFullImageProvider()
}

extension EnvironmentValues {
    var galleryThumbnailProvider: GalleryThumbnailProvider {
        get { self[GalleryThumbnailProviderKey.self] }
        set { self[GalleryThumbnailProviderKey.self] = newValue }
    }

    var galleryFullImageProvider: GalleryFullImageProvider {
        get { self[GalleryFullImageProviderKey.self] }
        set { self[GalleryFullImageProviderKey.self] = newValue }
    }
}
