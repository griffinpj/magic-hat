//
//  ImageLoader.swift
//  magic-hat
//
//  Two-tier card-image cache. Original bytes are cached on disk under Caches/
//  so images survive relaunches without bloating the SwiftData store; decoded,
//  downsampled UIImages are cached in memory keyed by URL + target size.
//
//  Crucially, decode + downsample happen off the main thread (on this actor)
//  via ImageIO, so scrolling the grid never triggers a main-thread decode of
//  a full-resolution card image — the usual cause of scroll jank.
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
    /// Order: memory → disk bytes → network. Decode/downsample runs here on
    /// the actor, off the main thread.
    func image(for urlString: String, maxPixel: CGFloat) async throws -> UIImage {
        let key = ImageMemoryCache.key(urlString, maxPixel)
        if let cached = ImageMemoryCache.shared.image(key) { return cached }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let file = fileURL(for: urlString)
        let task = Task<UIImage, Error> { [http] in
            let data: Data
            if let onDisk = try? Data(contentsOf: file) {
                data = onDisk
            } else {
                guard let url = URL(string: urlString) else { throw HTTPError.badURL }
                // Card images are on the general (10/sec) limit family.
                let downloaded = try await http.requestData(url: url, rateLimit: .other)
                try? downloaded.write(to: file, options: .atomic)
                data = downloaded
            }
            guard let img = Self.downsample(data: data, maxPixel: maxPixel) else {
                throw HTTPError.badURL
            }
            return img
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
