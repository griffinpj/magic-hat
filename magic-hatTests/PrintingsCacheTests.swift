//
//  PrintingsCacheTests.swift
//  magic-hatTests
//
//  The printings cache keeps a bounded number of cards in memory, least
//  recently used out first — the viewer warms every card it rests on, and
//  a basic land is hundreds of printings — and what leaves memory is
//  still a disk read away, never a second search.
//

import Testing
import Foundation
@testable import magic_hat

@MainActor
@Suite("PrintingsCache")
struct PrintingsCacheTests {
    actor Counter {
        private(set) var calls: [String] = []
        func record(_ id: String) { calls.append(id) }
    }

    private func cache(capacity: Int, counter: Counter) -> PrintingsCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrintingsCacheTests-\(UUID().uuidString)")
        return PrintingsCache(directory: dir, capacity: capacity) { oracleID in
            await counter.record(oracleID)
            return []
        }
    }

    @Test func memoryIsBoundedLeastRecentlyUsedFirst() async throws {
        let counter = Counter()
        let cache = cache(capacity: 3, counter: counter)
        for id in ["a", "b", "c"] { _ = try await cache.printings(oracleID: id) }
        #expect(cache.memoryKeys == ["a", "b", "c"])

        // Reading "a" makes it the most recent, so "b" is the one to go.
        #expect(cache.cached(oracleID: "a") != nil)
        _ = try await cache.printings(oracleID: "d")
        #expect(cache.memoryKeys == ["c", "a", "d"])
        #expect(cache.cached(oracleID: "b") == nil, "evicted from memory")
    }

    @Test func anEvictedCardComesBackFromDiskNotTheNetwork() async throws {
        let counter = Counter()
        let cache = cache(capacity: 1, counter: counter)
        _ = try await cache.printings(oracleID: "a")
        _ = try await cache.printings(oracleID: "b")
        #expect(cache.cached(oracleID: "a") == nil)
        _ = try await cache.printings(oracleID: "a")
        #expect(await counter.calls == ["a", "b"], "one search per card")
        #expect(cache.memoryKeys == ["a"])
    }

    @Test func theDefaultHoldsFiftyCards() async throws {
        let counter = Counter()
        let cache = cache(capacity: PrintingsCache.defaultCapacity, counter: counter)
        for i in 0..<60 { _ = try await cache.printings(oracleID: "card-\(i)") }
        #expect(cache.memoryKeys.count == 50)
        #expect(cache.memoryKeys.first == "card-10")
    }
}
