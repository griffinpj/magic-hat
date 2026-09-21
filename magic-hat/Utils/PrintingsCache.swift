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

    private struct Entry: Codable {
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

    /// Cached printings, or nil if absent/expired. Never hits the network —
    /// callers that only want an instant answer can use this.
    func cached(oracleID: String) -> [ScryfallCard]? {
        if let entry = memory[oracleID], isFresh(entry) { return entry.cards }
        guard let entry = readDisk(oracleID), isFresh(entry) else { return nil }
        memory[oracleID] = entry
        return entry.cards
    }

    func printings(oracleID: String) async throws -> [ScryfallCard] {
        if let cards = cached(oracleID: oracleID) { return cards }
        if let existing = inFlight[oracleID] { return try await existing.value }

        let task = Task { try await ScryfallClient.shared.printings(oracleID: oracleID) }
        inFlight[oracleID] = task
        defer { inFlight[oracleID] = nil }

        let cards = try await task.value
        let entry = Entry(cards: cards, fetchedAt: Date())
        memory[oracleID] = entry
        writeDisk(entry, oracleID: oracleID)
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

    private func readDisk(_ oracleID: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(oracleID)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    private func writeDisk(_ entry: Entry, oracleID: String) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(oracleID), options: .atomic)
    }
}
