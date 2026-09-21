//
//  PrintingsCache.swift
//  magic-hat
//
//  Caches "every printing of this card" by oracle id. The detail screen used
//  to re-run the paginated /cards/search query every time it opened, which is
//  the slowest endpoint family we touch (2/sec) and always returns the same
//  answer for the same card. Entries are deduped in flight and expire so new
//  printings eventually show up.
//

import Foundation

@MainActor
final class PrintingsCache {
    static let shared = PrintingsCache()

    /// Printings change only when a new set releases; a few hours is plenty.
    static let ttl: TimeInterval = 6 * 3600

    private struct Entry {
        let cards: [ScryfallCard]
        let fetchedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[ScryfallCard], Error>] = [:]

    func printings(oracleID: String) async throws -> [ScryfallCard] {
        if let entry = cache[oracleID],
           Date().timeIntervalSince(entry.fetchedAt) < Self.ttl {
            return entry.cards
        }
        if let existing = inFlight[oracleID] {
            return try await existing.value
        }

        let task = Task { try await ScryfallClient.shared.printings(oracleID: oracleID) }
        inFlight[oracleID] = task
        defer { inFlight[oracleID] = nil }

        let cards = try await task.value
        cache[oracleID] = Entry(cards: cards, fetchedAt: Date())
        return cards
    }
}
