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
import os
import UIKit
import SwiftUI
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
    func removeAll() {
        cache.removeAllObjects()
        tints.withLock { $0.removeAll() }
    }

    /// The art's colours, per URL (the same whatever size was decoded):
    /// a few bytes each, so every card seen this session keeps its glow
    /// after its image has been evicted. Read in a tile's body like the
    /// image, so a warmed tile glows in its first frame.
    private let tints = OSAllocatedUnfairLock(initialState: [String: ArtTint]())
    func tint(_ urlString: String) -> ArtTint? { tints.withLock { $0[urlString] } }
    func setTint(_ tint: ArtTint, _ urlString: String) {
        tints.withLock { table in
            if table.count > 4_000 { table.removeAll() }
            table[urlString] = tint
        }
    }
}

/// The colours of a card's art, worked out once when the image is
/// decoded (`ImageLoader.downsample`): the average of its top and bottom
/// thirds, and the frame's colour from its edges. What the grid's glass
/// cell glows with — a gradient, never a blur, so it costs the tile
/// nothing to draw.
nonisolated struct ArtTint: Hashable, Sendable {
    /// Red, green, blue in 0…1.
    let top: (Float, Float, Float)
    let bottom: (Float, Float, Float)

    static func == (a: ArtTint, b: ArtTint) -> Bool { a.top == b.top && a.bottom == b.bottom }

    var topColor: Color { Color(red: Double(top.0), green: Double(top.1), blue: Double(top.2)) }
    var bottomColor: Color { Color(red: Double(bottom.0), green: Double(bottom.1), blue: Double(bottom.2)) }
    /// The two mixed, for the glass's own tint.
    var midColor: Color {
        Color(red: Double(top.0 + bottom.0) / 2, green: Double(top.1 + bottom.1) / 2, blue: Double(top.2 + bottom.2) / 2)
    }
    func hash(into h: inout Hasher) { h.combine(top.0); h.combine(top.1); h.combine(top.2); h.combine(bottom.0); h.combine(bottom.1); h.combine(bottom.2) }

    /// Averages the image's rows over a 12×16 rendering: a few hundred
    /// pixels, microseconds, inside the decode that already ran off-main.
    /// The averages are then pushed a little towards saturation, since a
    /// mean of a whole card leans grey.
    static func extract(_ cg: CGImage) -> ArtTint? {
        let w = 12, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func average(rows: Range<Int>) -> (Float, Float, Float) {
            var r: Float = 0, g: Float = 0, b: Float = 0, n: Float = 0
            for y in rows {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    r += Float(pixels[i]); g += Float(pixels[i + 1]); b += Float(pixels[i + 2]); n += 1
                }
            }
            guard n > 0 else { return (0.5, 0.5, 0.5) }
            return boost((r / n / 255, g / n / 255, b / n / 255))
        }
        // Core Graphics draws bottom-up: the top of the art is the last rows.
        return ArtTint(top: average(rows: (h * 2 / 3)..<h), bottom: average(rows: 0..<(h / 3)))
    }

    /// More saturation, kept off black and white, so the glow reads as a
    /// colour rather than a shade.
    private static func boost(_ c: (Float, Float, Float)) -> (Float, Float, Float) {
        let mean = (c.0 + c.1 + c.2) / 3
        func push(_ v: Float) -> Float { min(1, max(0, mean + (v - mean) * 1.8)) }
        var out = (push(c.0), push(c.1), push(c.2))
        let luma = 0.299 * out.0 + 0.587 * out.1 + 0.114 * out.2
        if luma < 0.22 { let k = 0.22 / max(luma, 0.01); out = (min(1, out.0 * k), min(1, out.1 * k), min(1, out.2 * k)) }
        if luma > 0.85 { out = (out.0 * 0.85, out.1 * 0.85, out.2 * 0.85) }
        return out
    }
}

nonisolated enum ImageLoadError: Error { case meteredNetwork }

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

    /// Bytes on disk, for Settings.
    nonisolated func diskUsage() -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: keys)) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0) }
    }

    /// Removes every cached image, on disk and in memory. They stream back
    /// as cards are shown.
    func clearCache() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        if let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        ImageMemoryCache.shared.removeAll()
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
            if let onDisk = await Self.decodeFile(file, maxPixel: maxPixel, urlString: urlString) { return onDisk }
            // Settings can keep images off cellular: what is on disk shows,
            // the rest waits for Wi-Fi (the tile keeps its placeholder).
            guard AppSettings.imagesOnCellular || !NetworkMonitor.isMeteredNow else { throw ImageLoadError.meteredNetwork }
            guard let url = URL(string: urlString) else { throw HTTPError.badURL }
            // Card images have their own lane (see RateLimiter), so a
            // scroll never starves a hydration batch.
            let downloaded = try await http.requestData(url: url, rateLimit: .images)
            return try await Self.keepAndDecode(downloaded, at: file, maxPixel: maxPixel, urlString: urlString)
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
    private nonisolated static func decodeFile(_ file: URL, maxPixel: CGFloat, urlString: String) async -> UIImage? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return downsample(data: data, maxPixel: maxPixel, urlString: urlString)
    }

    @concurrent
    private nonisolated static func keepAndDecode(_ data: Data, at file: URL, maxPixel: CGFloat, urlString: String) async throws -> UIImage {
        try? data.write(to: file, options: .atomic)
        guard let image = downsample(data: data, maxPixel: maxPixel, urlString: urlString) else { throw HTTPError.badURL }
        return image
    }

    /// Decodes and downsamples image data to `maxPixel` (longest edge) using
    /// ImageIO, forcing an immediate decode so the returned UIImage is ready
    /// to render without further main-thread work.
    private nonisolated static func downsample(data: Data, maxPixel: CGFloat, urlString: String? = nil) -> UIImage? {
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
        // The art's colours, while the decoded pixels are in hand.
        if let urlString, ImageMemoryCache.shared.tint(urlString) == nil, let tint = ArtTint.extract(cg) {
            ImageMemoryCache.shared.setTint(tint, urlString)
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
