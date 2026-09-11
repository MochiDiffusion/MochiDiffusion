//
//  GalleryImageProviders.swift
//  Mochi Diffusion
//

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Downsampled thumbnails for the gallery grid, read from disk rather than from a
/// decoded image in memory.
///
/// The gallery used to hold a full-size `CGImage` for every entry. A decoded
/// 1024x1024 image is about 4 MB, so a few hundred images was gigabytes resident
/// for pictures rendered a couple of hundred points wide.
///
/// Two things keep that from being traded for churn. The `NSCache` lets the system
/// evict under pressure rather than growing without bound, and `inFlightRequests`
/// coalesces concurrent asks for the same path and size — scrolling produces a burst
/// of identical requests, and without it each would decode its own copy.
actor GalleryThumbnailProvider {
    /// `NSCache` needs a class, and `CGImage` is not one.
    private final class CachedThumbnail {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CachedThumbnail>()
    private var inFlightRequests: [String: Task<CGImage?, Never>] = [:]

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

        if let image {
            cache.setObject(CachedThumbnail(image), forKey: cacheKey as NSString)
        }

        return image
    }

    /// Drops what is cached for a path, for a file that changed or went away.
    ///
    /// Size-agnostic: the cache is keyed by path *and* size, so clearing one entry
    /// would leave the others stale. `NSCache` cannot enumerate its keys, so this
    /// empties it — coarse, and correct, and rare.
    func invalidate() {
        cache.removeAllObjects()
    }

    private func cacheKey(for path: String, maxPixelSize: Int) -> String {
        "\(path)#\(maxPixelSize)"
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

        if let cached = cache.object(forKey: path as NSString) {
            return cached.image
        }

        if let request = inFlightRequests[path] {
            return await request.value
        }

        let imageLoader = imageLoader
        let request = Task(priority: .utility) {
            await imageLoader(path)
        }
        inFlightRequests[path] = request

        let image = await request.value
        inFlightRequests[path] = nil

        if let image {
            cache.setObject(CachedImage(image), forKey: path as NSString)
        }

        return image
    }

    func invalidate() {
        cache.removeAllObjects()
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
