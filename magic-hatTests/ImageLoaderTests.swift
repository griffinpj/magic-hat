//
//  ImageLoaderTests.swift
//  magic-hatTests
//
//  The loader's shared loads, against a stand-in fetch (no network): a
//  load nobody waits on any more is cancelled down to the request — a
//  flick through a cold region used to queue a request per tile passed —
//  one waiter leaving doesn't cancel it for the others, and the viewer's
//  and the grid's sizes of one card share a single download.
//

import Testing
import UIKit
@testable import magic_hat

@Suite("ImageLoader")
struct ImageLoaderTests {
    /// Counts what the stand-in fetch saw.
    actor Probe {
        private(set) var started = 0
        private(set) var cancelled = 0
        func start() { started += 1 }
        func cancel() { cancelled += 1 }
    }

    private static let png: Data = {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 68))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 68))
        }
    }()

    private func loader(probe: Probe, delay: Duration) -> ImageLoader {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ImageLoaderTests-\(UUID().uuidString)")
        let png = Self.png
        return ImageLoader(cacheDirectory: dir) { _ in
            await probe.start()
            do {
                try await Task.sleep(for: delay)
            } catch {
                await probe.cancel()
                throw error
            }
            return png
        }
    }

    private static func idle(_ loader: ImageLoader) async -> Bool {
        let counts = await loader.inFlightCounts
        return counts.decodes == 0 && counts.downloads == 0
    }

    /// A unique URL per test: the memory cache is shared by the process.
    private func url() -> String { "https://cards.example/\(UUID().uuidString).png" }

    /// Polls `condition` for up to `seconds`.
    private func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    @Test func cancellingTheOnlyWaiterCancelsTheRequest() async throws {
        let probe = Probe()
        let loader = loader(probe: probe, delay: .seconds(30))
        let url = url()
        let waiter = Task { try await loader.image(for: url, maxPixel: 100) }
        #expect(await eventually { await probe.started == 1 })
        waiter.cancel()
        #expect(await eventually { await probe.cancelled == 1 }, "the request saw the cancellation")
        #expect(await eventually { await Self.idle(loader) }, "nothing left in flight")
        await #expect(throws: (any Error).self) { try await waiter.value }
    }

    @Test func oneWaiterLeavingKeepsTheLoadForTheOthers() async throws {
        let probe = Probe()
        let loader = loader(probe: probe, delay: .milliseconds(600))
        let url = url()
        let leaving = Task { try await loader.image(for: url, maxPixel: 100) }
        let staying = Task { try await loader.image(for: url, maxPixel: 100) }
        #expect(await eventually { await probe.started == 1 })
        leaving.cancel()
        let image = try await staying.value
        #expect(image.size.width > 0)
        #expect(await probe.started == 1, "one request for both")
        #expect(await probe.cancelled == 0)
    }

    @Test func twoSizesShareOneDownload() async throws {
        let probe = Probe()
        let loader = loader(probe: probe, delay: .milliseconds(300))
        let url = url()
        async let small = loader.image(for: url, maxPixel: 40)
        async let large = loader.image(for: url, maxPixel: 200)
        let (a, b) = try await (small, large)
        #expect(a.size.width > 0 && b.size.width > 0)
        #expect(await probe.started == 1, "the bytes were downloaded once")
        #expect(await Self.idle(loader))
    }

    @Test func aRejoinWithinTheGraceKeepsTheRequest() async throws {
        // The grid's warm pass is cancelled and restarted a few tiles on;
        // the overlap must not lose its place in the lane.
        let probe = Probe()
        let loader = loader(probe: probe, delay: .milliseconds(600))
        let url = url()
        let first = Task { try await loader.image(for: url, maxPixel: 100) }
        #expect(await eventually { await probe.started == 1 })
        first.cancel()
        let second = try await loader.image(for: url, maxPixel: 100)
        #expect(second.size.width > 0)
        #expect(await probe.started == 1, "rejoined, not restarted")
        #expect(await probe.cancelled == 0)
    }
}
