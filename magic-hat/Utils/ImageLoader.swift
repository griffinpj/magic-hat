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
/// decoded (`ImageLoader.downsample`): eight samples around the inside
/// of the **art box** — the corners and the middle of each side of the
/// picture, not the frame — and their mean. What the grid's glass cell
/// glows with, as a mesh gradient whose edge colours are the art's own
/// edge colours: a sunset over a dark sea bleeds orange at the top and
/// navy at the bottom. The frame is left out on purpose — a white card's
/// title bar and text box turned every white card's glow grey, and the
/// frame's colour already shows on the card itself. A gradient, never a
/// blur, so it costs the tile one fill to draw.
nonisolated struct ArtTint: Hashable, Sendable {
    /// Red, green, blue in 0…1: top-left, top, top-right, left, centre,
    /// right, bottom-left, bottom, bottom-right — a 3×3 mesh, row by row.
    let samples: [SIMD3<Float>]

    init(samples: [SIMD3<Float>]) {
        precondition(samples.count == 9)
        self.samples = samples
    }

    /// Two colours, top and bottom, for anything that wants a plain gradient.
    init(top: (Float, Float, Float), bottom: (Float, Float, Float)) {
        let t = SIMD3(top.0, top.1, top.2), b = SIMD3(bottom.0, bottom.1, bottom.2)
        let m = (t + b) / 2
        samples = [t, t, t, m, m, m, b, b, b]
    }

    static func color(_ c: SIMD3<Float>) -> Color { Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)) }
    var colors: [Color] { samples.map(Self.color) }
    var topColor: Color { Self.color((samples[0] + samples[1] + samples[2]) / 3) }
    var bottomColor: Color { Self.color((samples[6] + samples[7] + samples[8]) / 3) }
    /// The mean of the art, for the glass's own tint.
    var midColor: Color { Self.color(samples[4]) }

    /// The 3×3 mesh's points: the corners and side midpoints of the unit
    /// square, the centre in the middle.
    static let meshPoints: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    /// Where the picture sits on a card with the standard frame, as
    /// fractions of the card: inside the title bar, above the type line.
    /// Full-art and borderless cards have art there too; a saga or a
    /// split card mixes some text in, which the mean softens.
    static let artBox = CGRect(x: 0.075, y: 0.11, width: 0.85, height: 0.45)

    /// Samples a 48×64 rendering of the card — three thousand pixels,
    /// microseconds, inside the decode that already ran off-main. The art
    /// box is cut out of it and a three-cell ring just inside the box's
    /// edge is read in eight patches. Each is then pushed a little towards
    /// saturation, since a mean leans grey.
    static func extract(_ cg: CGImage) -> ArtTint? {
        let w = 48, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Memory row 0 is the top of the image: Core Graphics draws with
        // y up, and the context's top edge is the buffer's first row.
        func average(x xs: Range<Int>, y ys: Range<Int>) -> SIMD3<Float> {
            var sum = SIMD3<Float>(repeating: 0)
            var n: Float = 0
            for y in ys {
                for x in xs {
                    let i = (y * w + x) * 4
                    sum += SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]))
                    n += 1
                }
            }
            guard n > 0 else { return SIMD3(repeating: 0.5) }
            return boost(sum / n / 255)
        }
        // The art box in cells, then a ring three cells deep inside it; the
        // side patches take the middle third of each edge.
        let x0 = Int((artBox.minX * CGFloat(w)).rounded()), x1 = Int((artBox.maxX * CGFloat(w)).rounded())
        let y0 = Int((artBox.minY * CGFloat(h)).rounded()), y1 = Int((artBox.maxY * CGFloat(h)).rounded())
        let ring = 3
        let left = x0..<(x0 + ring), right = (x1 - ring)..<x1
        let top = y0..<(y0 + ring), bottom = (y1 - ring)..<y1
        let midX = (x0 + (x1 - x0) / 3)..<(x1 - (x1 - x0) / 3)
        let midY = (y0 + (y1 - y0) / 3)..<(y1 - (y1 - y0) / 3)
        let tl = average(x: left, y: top)
        let t = average(x: midX, y: top)
        let tr = average(x: right, y: top)
        let l = average(x: left, y: midY)
        let r = average(x: right, y: midY)
        let bl = average(x: left, y: bottom)
        let b = average(x: midX, y: bottom)
        let br = average(x: right, y: bottom)
        var centre = tl + t
        centre += tr + l
        centre += r + bl
        centre += b + br
        centre /= 8
        return ArtTint(samples: [tl, t, tr, l, centre, r, bl, b, br])
    }

    /// More saturation, kept off black and white, so the glow reads as a
    /// colour rather than a shade.
    private static func boost(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let mean = (c.x + c.y + c.z) / 3
        var out = (SIMD3(repeating: mean) + (c - SIMD3(repeating: mean)) * 1.8).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
        let luma = 0.299 * out.x + 0.587 * out.y + 0.114 * out.z
        if luma < 0.22 { let k = 0.22 / max(luma, 0.01); out = (out * k).clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)) }
        if luma > 0.85 { out *= 0.85 }
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
