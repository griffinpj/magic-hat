//
//  PrintingsCache.swift
//  magic-hat
//
//  Caches "every printing of this card" by oracle id. /cards/search is the
//  slowest endpoint family we touch (2/sec, paginated) and returns the same
//  answer for the same card until a set that reprints it releases — which is
//  roughly monthly. So the cache is long-lived and written to disk, meaning a
//  cold launch doesn't re-run searches the app has already done.
//

import Foundation

@MainActor
final class PrintingsCache {
    static let shared = PrintingsCache()

    /// New printings only appear when a set releases; a week is comfortably
    /// fresh and removes essentially all repeat traffic.
    nonisolated static let ttl: TimeInterval = 7 * 24 * 3600

    /// Cards kept in memory. Every card the viewer rests on is warmed here,
    /// and a basic land is hundreds of printings: unbounded, a long session
    /// of swiping kept every one of them. The rest are a disk read away.
    nonisolated static let defaultCapacity = 50

    nonisolated private struct Entry: Codable, Sendable {
        let cards: [ScryfallCard]
        let fetchedAt: Date
    }

    private var memory: [String: Entry] = [:]
    /// Oracle ids in memory, least recently used first.
    private var recency: [String] = []
    private let capacity: Int
    private var inFlight: [String: Task<Entry, Error>] = [:]

    private let directory: URL
    private let fm = FileManager.default
    /// The search for a card's printings: Scryfall in the app, a stand-in
    /// in tests.
    private let fetch: @Sendable (String) async throws -> [ScryfallCard]

    init(directory: URL? = nil, capacity: Int = PrintingsCache.defaultCapacity,
         fetch: (@Sendable (String) async throws -> [ScryfallCard])? = nil) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? caches.appendingPathComponent("Printings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.capacity = max(1, capacity)
        self.fetch = fetch ?? { oracleID in try await ScryfallClient.shared.printings(oracleID: oracleID) }
    }

    /// Printings already in memory, or nil. Never touches disk or the
    /// network — the instant answer for a view that is drawing right now.
    /// (It used to read and decode the disk entry here, on the main actor:
    /// every printing of the card, hundreds for a basic land, once per
    /// card the pager rested on — the stalls while swiping the viewer.)
    func cached(oracleID: String) -> [ScryfallCard]? {
        if let entry = memory[oracleID], isFresh(entry) {
            touch(oracleID)
            return entry.cards
        }
        return nil
    }

    /// Oracle ids held in memory, least recently used first (tests).
    var memoryKeys: [String] { recency }

    func printings(oracleID: String) async throws -> [ScryfallCard] {
        if let cards = cached(oracleID: oracleID) { return cards }
        if let existing = inFlight[oracleID] { return try await existing.value.cards }

        let file = fileURL(oracleID)
        let fetch = self.fetch
        let task = Task { () throws -> Entry in
            if let entry = await Self.readDisk(file), Self.isFresh(entry) {
                return entry
            }
            let entry = Entry(cards: try await fetch(oracleID), fetchedAt: Date())
            await Self.writeDisk(entry, to: file)
            return entry
        }
        inFlight[oracleID] = task
        defer { inFlight[oracleID] = nil }

        // Kept with the date it was fetched, so one read from disk doesn't
        // restart its week.
        let entry = try await task.value
        remember(entry, for: oracleID)
        return entry.cards
    }

    /// Warms the cache without caring about the result (used while browsing
    /// the overlay so opening the detail screen is instant).
    func prefetch(oracleID: String) async {
        _ = try? await printings(oracleID: oracleID)
    }

    // MARK: Memory

    private func remember(_ entry: Entry, for oracleID: String) {
        memory[oracleID] = entry
        touch(oracleID)
        while recency.count > capacity {
            memory[recency.removeFirst()] = nil
        }
    }

    private func touch(_ oracleID: String) {
        if let i = recency.firstIndex(of: oracleID) { recency.remove(at: i) }
        recency.append(oracleID)
    }

    // MARK: Disk

    private func isFresh(_ entry: Entry) -> Bool { Self.isFresh(entry) }

    nonisolated private static func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < ttl
    }

    private func fileURL(_ oracleID: String) -> URL {
        // Oracle ids are UUIDs, so they are already filesystem-safe.
        directory.appendingPathComponent("\(oracleID).json")
    }

    // Read, decode, encode and write on the global executor — see
    // HTTPClient.decode for why a nonisolated async function is not enough.
    @concurrent
    private static func readDisk(_ url: URL) async -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    @concurrent
    private static func writeDisk(_ entry: Entry, to url: URL) async {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
