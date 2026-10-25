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
        // a count-only limit could hold hundreds of MB and thrash. A 3-wide
        // tile on a 440pt phone is ~370×520px, 0.75MB: about 300 tiles,
        // ten screens either way, before anything is decoded twice.
        cache.totalCostLimit = 256 * 1024 * 1024
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

/// The colours around a card's edge, worked out once when the image is
/// decoded (`ImageLoader.downsample`): eight samples of the frame just
/// inside the printed border — the corners and the middle of each side —
/// and the mean of them. What the grid's glass cell glows with, as a
/// mesh gradient whose edge colours are the card's own edge colours, so a
/// card with a red frame on the left and a white one on the right (a
/// hybrid) bleeds red on the left and white on the right. A gradient,
/// never a blur, so it costs the tile one fill to draw.
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
    /// The mean of the edge, for the glass's own tint.
    var midColor: Color { Self.color(samples[4]) }

    /// The 3×3 mesh's points: the corners and side midpoints of the unit
    /// square, the centre in the middle.
    static let meshPoints: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.5, 0.5], [1, 0.5],
        [0, 1], [0.5, 1], [1, 1],
    ]

    /// Samples a 24×32 rendering of the card — a few hundred pixels,
    /// microseconds, inside the decode that already ran off-main. The
    /// printed black border is the outer cell or so (about 4.5% of the
    /// width); the ring two to three cells in is the frame, which is
    /// what sits against the glass. Each sample is then pushed a little
    /// towards saturation, since a mean leans grey.
    static func extract(_ cg: CGImage) -> ArtTint? {
        let w = 24, h = 32
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
        // The frame band: cells 2–3 in from each edge (8–16% of the width),
        // past the black border, short of the art.
        let band = 2..<4
        let third = (w / 3, h / 3)
        let tl = average(x: band, y: band)
        let t = average(x: third.0..<(w - third.0), y: band)
        let tr = average(x: (w - 4)..<(w - 2), y: band)
        let l = average(x: band, y: third.1..<(h - third.1))
        let r = average(x: (w - 4)..<(w - 2), y: third.1..<(h - third.1))
        let bl = average(x: band, y: (h - 4)..<(h - 2))
        let b = average(x: third.0..<(w - third.0), y: (h - 4)..<(h - 2))
        let br = average(x: (w - 4)..<(w - 2), y: (h - 4)..<(h - 2))
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

/// One shared load and how many callers are waiting on it. `waiters` is
/// only read and written on `ImageLoader` (the cancellation handler hops
/// back onto it), hence the unchecked conformance.
nonisolated private final class ImageFlight<Value: Sendable>: @unchecked Sendable {
    let task: Task<Value, Error>
    var waiters = 0
    init(_ task: Task<Value, Error>) { self.task = task }
}

actor ImageLoader {
    static let shared = ImageLoader()

    private let fm = FileManager.default
    private let cacheDir: URL
    /// The network fetch: the images lane in production, a stand-in in
    /// tests (which never touch the network).
    private let fetch: @Sendable (URL) async throws -> Data

    /// Decodes in flight, keyed by "url|maxPixel", so a tile and the warm
    /// pass asking for the same image share one decode.
    private var decodes: [String: ImageFlight<UIImage>] = [:]
    /// Downloads in flight, keyed by URL alone: the viewer and the grid
    /// ask for the same card at different sizes, and used to download its
    /// bytes once per size.
    private var downloads: [String: ImageFlight<Data>] = [:]

    init(cacheDirectory: URL? = nil, fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = cacheDirectory ?? caches.appendingPathComponent("CardImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let fetch {
            self.fetch = fetch
        } else {
            let http = HTTPClient()
            // Card images have their own lane (see RateLimiter), so a
            // scroll never starves a hydration batch.
            self.fetch = { url in try await http.requestData(url: url, rateLimit: .images) }
        }
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
        for flight in decodes.values { flight.task.cancel() }
        for flight in downloads.values { flight.task.cancel() }
        decodes.removeAll()
        downloads.removeAll()
        if let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        ImageMemoryCache.shared.removeAll()
    }

    /// Loads a card image downsampled to `maxPixel` (longest edge, in pixels).
    /// Order: memory → disk bytes → network. Reading and decoding run off
    /// the main thread and off this actor (see `decodeFile`).
    ///
    /// Cancellation reaches the request: the load is shared by everyone
    /// asking for the same image, and when the last of them is cancelled
    /// (a tile scrolled away, the warm pass moved on) the load is too. It
    /// used to run in a task nobody could cancel, so a flick through a
    /// cold region queued a request per tile passed in the 5/sec lane and
    /// the tiles on screen waited behind them.
    func image(for urlString: String, maxPixel: CGFloat) async throws -> UIImage {
        let key = ImageMemoryCache.key(urlString, maxPixel)
        if let cached = ImageMemoryCache.shared.image(key) { return cached }
        lastInteractiveLoad = .now

        let file = fileURL(for: urlString)
        let flight = decodes[key] ?? {
            let made = ImageFlight(Task<UIImage, Error> {
                // A cancelled load (Clear Image Cache cancels them all) caches
                // nothing: one already past its decode used to put its image
                // back right after the cache was emptied.
                if let onDisk = await Self.decodeFile(file, maxPixel: maxPixel, urlString: urlString) {
                    try Task.checkCancellation()
                    ImageMemoryCache.shared.set(onDisk, key)
                    return onDisk
                }
                let data = try await self.download(urlString, to: file)
                guard let image = await Self.decode(data, maxPixel: maxPixel, urlString: urlString) else {
                    throw HTTPError.badURL
                }
                try Task.checkCancellation()
                ImageMemoryCache.shared.set(image, key)
                return image
            })
            decodes[key] = made
            return made
        }()
        return try await wait(on: flight) { [weak self] in
            await self?.leave(flight, decodes: key)
        } finish: {
            if decodes[key] === flight { decodes[key] = nil }
        }
    }

    /// The bytes of `urlString`, downloaded once however many sizes ask
    /// for it, and kept on disk. Refuses a metered path unless images are
    /// allowed on cellular: what is on disk still shows, the rest waits
    /// for Wi-Fi (the tile keeps its placeholder).
    private func download(_ urlString: String, to file: URL) async throws -> Data {
        let flight = downloads[urlString] ?? {
            let made = ImageFlight(Task<Data, Error> { [fetch] in
                guard AppSettings.imagesOnCellular || !NetworkMonitor.isMeteredNow else { throw ImageLoadError.meteredNetwork }
                guard let url = URL(string: urlString) else { throw HTTPError.badURL }
                // Nobody wants it any more: don't spend a slot in the lane.
                try Task.checkCancellation()
                let data = try await fetch(url)
                // Not written into a cache cleared while it was downloading.
                try Task.checkCancellation()
                try? await Self.keep(data, at: file)
                return data
            })
            downloads[urlString] = made
            return made
        }()
        return try await wait(on: flight) { [weak self] in
            await self?.leave(flight, downloads: urlString)
        } finish: {
            if downloads[urlString] === flight { downloads[urlString] = nil }
        }
    }

    /// Waits on a shared load as one of its waiters. A waiter cancelled
    /// leaves (`onLeave`, hopped back onto the actor); the load is cancelled
    /// when the last one has left. `finish` drops the finished load from
    /// its table.
    private func wait<Value: Sendable>(on flight: ImageFlight<Value>,
                                       onLeave: @escaping @Sendable () async -> Void,
                                       finish: () -> Void) async throws -> Value {
        flight.waiters += 1
        let result = await withTaskCancellationHandler {
            await flight.task.result
        } onCancel: {
            Task { await onLeave() }
        }
        finish()
        return try result.get()
    }

    /// How long a load nobody waits on is kept before it is cancelled.
    /// The grid's warm pass is cancelled and restarted a few tiles on, and
    /// most of the new window is the old one: without a grace each restart
    /// cancelled those downloads and queued them again at the back of the
    /// images lane.
    static let rejoinGrace: Duration = .milliseconds(250)

    private func leave(_ flight: ImageFlight<UIImage>, decodes key: String) async {
        flight.waiters -= 1
        guard flight.waiters <= 0 else { return }
        try? await Task.sleep(for: Self.rejoinGrace)
        guard flight.waiters <= 0 else { return }
        flight.task.cancel()
        if decodes[key] === flight { decodes[key] = nil }
    }

    private func leave(_ flight: ImageFlight<Data>, downloads key: String) async {
        flight.waiters -= 1
        guard flight.waiters <= 0 else { return }
        try? await Task.sleep(for: Self.rejoinGrace)
        guard flight.waiters <= 0 else { return }
        flight.task.cancel()
        if downloads[key] === flight { downloads[key] = nil }
    }

    /// Loads in flight, for tests: (decodes, downloads).
    var inFlightCounts: (decodes: Int, downloads: Int) { (decodes.count, downloads.count) }

    /// Loads the images in order, a few at a time, skipping what is
    /// already decoded, and stops at cancellation. A few, not all thirty:
    /// the grid's own tile loads interleave between these and keep their
    /// place in the rate limiter, rather than queueing behind the whole
    /// window. Not one at a time either: a disk hit is a read and a
    /// decode, a few milliseconds each, and one after another they fell
    /// behind a flick.
    func warm(_ urls: [String], maxPixel: CGFloat) async {
        let pending = urls.filter { ImageMemoryCache.shared.image(ImageMemoryCache.key($0, maxPixel)) == nil }
        guard !pending.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var next = pending.makeIterator()
            for _ in 0..<Self.warmWidth {
                guard let url = next.next() else { break }
                group.addTask { _ = try? await self.image(for: url, maxPixel: maxPixel) }
            }
            while await group.next() != nil {
                if Task.isCancelled { return }
                guard let url = next.next() else { continue }
                group.addTask { _ = try? await self.image(for: url, maxPixel: maxPixel) }
            }
        }
    }

    /// Images decoded at once by `warm`.
    private static let warmWidth = 3

    // MARK: Prefetching the whole collection

    /// When the grid last asked for an image it didn't have in memory —
    /// the user is scrolling. The prefetch stands aside while this is
    /// recent, so its downloads never queue ahead of a tile's in the
    /// images lane.
    private var lastInteractiveLoad: ContinuousClock.Instant = .now - .seconds(60)
    private static let interactiveGrace: Duration = .milliseconds(1500)

    /// The URLs among `urls` with no bytes on disk yet, checked off the
    /// actor (a stat per card; thousands of them).
    @concurrent
    nonisolated func missingFromDisk(_ urls: [String]) async -> [String] {
        let fm = FileManager.default
        return urls.filter { !fm.fileExists(atPath: fileURL(for: $0).path) }
    }

    /// Downloads `urls` to the disk cache, one at a time, in the images
    /// lane, without decoding — bytes for the grid to find later, so a
    /// scroll into a part of the collection never seen meets images on
    /// disk rather than filling in at the lane's rate. Yields while the
    /// grid is loading, stops at cancellation, and refuses a metered path
    /// unless images are allowed on cellular (checked per image, so
    /// leaving Wi-Fi stops it). Reports every `every` images.
    func prefetch(_ urls: [String], every: Int = 25, progress: @Sendable (Int) async -> Void) async -> (fetched: Int, failed: Int) {
        var fetched = 0, failed = 0
        for (i, url) in urls.enumerated() {
            if Task.isCancelled { break }
            while ContinuousClock.now - lastInteractiveLoad < Self.interactiveGrace {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return (fetched, failed) }
            }
            guard AppSettings.imagesOnCellular || !NetworkMonitor.isMeteredNow else { break }
            let file = fileURL(for: url)
            if fm.fileExists(atPath: file.path) { continue }
            do {
                // The same shared download a tile would join, so a tile
                // asking for this card meanwhile waits on it, not a second.
                _ = try await download(url, to: file)
                fetched += 1
            } catch {
                if Task.isCancelled { break }
                failed += 1
            }
            if (i + 1) % every == 0 { await progress(i + 1) }
        }
        return (fetched, failed)
    }

    @concurrent
    private nonisolated static func keep(_ data: Data, at file: URL) async throws {
        try data.write(to: file, options: .atomic)
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
    private nonisolated static func decode(_ data: Data, maxPixel: CGFloat, urlString: String) async -> UIImage? {
        downsample(data: data, maxPixel: maxPixel, urlString: urlString)
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

    nonisolated private func fileURL(for urlString: String) -> URL {
        // Stable (cross-launch), filesystem-safe name derived from the URL.
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("\(name).img")
    }
}
