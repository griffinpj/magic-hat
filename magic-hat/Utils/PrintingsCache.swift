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
    static let ttl: TimeInterval = 7 * 24 * 3600

    nonisolated private struct Entry: Codable, Sendable {
        let cards: [ScryfallCard]
        let fetchedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<[ScryfallCard], Error>] = [:]

    private let directory: URL
    private let fm = FileManager.default

    init() {
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Printings", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Printings already in memory, or nil. Never touches disk or the
    /// network — the instant answer for a view that is drawing right now.
    /// (It used to read and decode the disk entry here, on the main actor:
    /// every printing of the card, hundreds for a basic land, once per
    /// card the pager rested on — the stalls while swiping the viewer.)
    func cached(oracleID: String) -> [ScryfallCard]? {
        if let entry = memory[oracleID], isFresh(entry) { return entry.cards }
        return nil
    }

    func printings(oracleID: String) async throws -> [ScryfallCard] {
        if let cards = cached(oracleID: oracleID) { return cards }
        if let existing = inFlight[oracleID] { return try await existing.value }

        let task = Task { () throws -> [ScryfallCard] in
            if let entry = await Self.readDisk(self.fileURL(oracleID)), self.isFresh(entry) {
                return entry.cards
            }
            let cards = try await ScryfallClient.shared.printings(oracleID: oracleID)
            await Self.writeDisk(Entry(cards: cards, fetchedAt: Date()), to: self.fileURL(oracleID))
            return cards
        }
        inFlight[oracleID] = task
        defer { inFlight[oracleID] = nil }

        let cards = try await task.value
        memory[oracleID] = Entry(cards: cards, fetchedAt: Date())
        return cards
    }

    /// Warms the cache without caring about the result (used while browsing
    /// the overlay so opening the detail screen is instant).
    func prefetch(oracleID: String) async {
        _ = try? await printings(oracleID: oracleID)
    }

    // MARK: Disk

    private func isFresh(_ entry: Entry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < Self.ttl
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
