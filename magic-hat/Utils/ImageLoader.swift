//
//  ImageLoader.swift
//  magic-hat
//
//  Two-tier card-image cache. Original bytes are cached on disk under Caches/
//  so images survive relaunches without bloating the SwiftData store; decoded,
//  downsampled UIImages are cached in memory keyed by URL + target size.
//
//  Crucially, decode + downsample happen off the main thread (on the global
//  executor, several at once) via ImageIO, so scrolling the grid never
//  triggers a main-thread decode of a full-resolution card image — the
//  usual cause of scroll jank.
//

import Foundation
import UIKit
import ImageIO
import CryptoKit

/// Thread-safe, synchronously readable in-memory image cache. Lives outside
/// the actor so views can check for a decoded image without an async hop —
/// scrolling reuses images instantly with no placeholder flash.
nonisolated final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()
    private let cache = NSCache<NSString, UIImage>()

    init() {
        cache.countLimit = 400
        // Bound by bytes too: an overlay-sized card decodes to several MB, so
        // a count-only limit could hold hundreds of MB and thrash.
        cache.totalCostLimit = 192 * 1024 * 1024
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 1 }
        return cg.bytesPerRow * cg.height
    }

    static func key(_ urlString: String, _ maxPixel: CGFloat) -> String {
        "\(urlString)|\(Int(maxPixel))"
    }

    func image(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func set(_ image: UIImage, _ key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private let http = HTTPClient()
    private let fm = FileManager.default
    private let cacheDir: URL

    /// In-flight loads keyed by "url|maxPixel", to coalesce duplicate requests.
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = caches.appendingPathComponent("CardImages", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Loads a card image downsampled to `maxPixel` (longest edge, in pixels).
    /// Order: memory → disk bytes → network. Reading and decoding run off
    /// the main thread and off this actor (see `decodeFile`).
    func image(for urlString: String, maxPixel: CGFloat) async throws -> UIImage {
        let key = ImageMemoryCache.key(urlString, maxPixel)
        if let cached = ImageMemoryCache.shared.image(key) { return cached }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let file = fileURL(for: urlString)
        let task = Task<UIImage, Error> { [http] in
            if let onDisk = await Self.decodeFile(file, maxPixel: maxPixel) { return onDisk }
            guard let url = URL(string: urlString) else { throw HTTPError.badURL }
            // Card images are on the general (10/sec) limit family.
            let downloaded = try await http.requestData(url: url, rateLimit: .other)
            return try await Self.keepAndDecode(downloaded, at: file, maxPixel: maxPixel)
        }
        inFlight[key] = task

        do {
            let img = try await task.value
            inFlight[key] = nil
            ImageMemoryCache.shared.set(img, key)
            return img
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    /// Loads each image in turn, skipping what is already decoded, and
    /// stops at cancellation. Sequential on purpose: the grid's own tile
    /// loads interleave between these and keep their place in the rate
    /// limiter, rather than queueing behind thirty prefetches.
    func warm(_ urls: [String], maxPixel: CGFloat) async {
        for url in urls {
            if Task.isCancelled { return }
            if ImageMemoryCache.shared.image(ImageMemoryCache.key(url, maxPixel)) != nil { continue }
            _ = try? await image(for: url, maxPixel: maxPixel)
        }
    }

    // Disk and decode on the global executor, several at once. The task
    // above inherits this actor, so they used to run *on* it, one at a
    // time: the viewer's large image decoded only after whatever the grid
    // had queued to warm, and every `image(for:)` call — even a memory
    // hit — waited behind the decode in progress.

    /// The cached original, decoded; nil if absent or unreadable (a
    /// corrupt file is then fetched again rather than failing forever).
    @concurrent
    private nonisolated static func decodeFile(_ file: URL, maxPixel: CGFloat) async -> UIImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return downsample(data: data, maxPixel: maxPixel)
    }

    @concurrent
    private nonisolated static func keepAndDecode(_ data: Data, at file: URL, maxPixel: CGFloat) async throws -> UIImage {
        try? data.write(to: file, options: .atomic)
        guard let image = downsample(data: data, maxPixel: maxPixel) else { throw HTTPError.badURL }
        return image
    }

    /// Decodes and downsamples image data to `maxPixel` (longest edge) using
    /// ImageIO, forcing an immediate decode so the returned UIImage is ready
    /// to render without further main-thread work.
    private nonisolated static func downsample(data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else {
            return nil
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    private func fileURL(for urlString: String) -> URL {
        // Stable (cross-launch), filesystem-safe name derived from the URL.
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).img")
    }
}
