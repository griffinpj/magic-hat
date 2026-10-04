//
//  CommanderFinder.swift
//  magic-hat
//
//  "Build with what you have": the hundred commanders people build most
//  (EDHREC, this week / month / two years), each scored by how much of
//  its average deck — the hundred cards most of its decks agree on — the
//  collection already holds. One request for the list and one per
//  commander for its average deck, paced at EDHREC's 2/sec and cached a
//  week (`DiskJSONCache`), so a scan is under a minute the first time
//  and instant after; the rows land as they are scored, best first, and
//  leaving the screen does not stop the scan. The matching itself
//  (`CommanderMatch.score`) is a pure count by card name, tested on its
//  own. Shared with nothing in the deck analysis.
//

import Foundation
import SwiftData
import Observation

/// One commander against the collection.
nonisolated struct CommanderMatch: Identifiable, Hashable, Sendable {
    struct Line: Hashable, Sendable, Identifiable {
        let name: String
        let needed: Int
        let owned: Int
        var id: String { name }
        var missing: Int { max(0, needed - owned) }
    }

    let slug: String
    let name: String
    let rank: Int
    let numDecks: Int
    /// The average deck, commander left out: copies wanted and held.
    let lines: [Line]
    var commanderOwned = false
    var artURL: String?
    var imageURL: String?
    var scryfallID: String?

    var id: String { slug }
    var totalCopies: Int { lines.reduce(0) { $0 + $1.needed } }
    var ownedCopies: Int { lines.reduce(0) { $0 + $1.owned } }
    var missingCopies: Int { totalCopies - ownedCopies }
    /// Share of the average deck already owned, 0–1.
    var share: Double { totalCopies > 0 ? Double(ownedCopies) / Double(totalCopies) : 0 }
    var missingLines: [Line] { lines.filter { $0.missing > 0 } }
    var ownedLines: [Line] { lines.filter { $0.owned > 0 } }

    /// Front-face name, lowercased: how owned cards and the list are matched.
    static func key(_ name: String) -> String {
        (name.components(separatedBy: " // ").first ?? name).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Counts the average deck's entries against owned copies by name.
    static func score(slug: String, name: String, rank: Int, numDecks: Int,
                      entries: [EDHRECAverageDeck.Entry], owned: [String: Int]) -> CommanderMatch {
        var lines: [Line] = []
        var seen = Set<String>()
        for entry in entries {
            let k = key(entry.name)
            guard !seen.contains(k) else { continue }
            seen.insert(k)
            let needed = max(1, entry.count)
            lines.append(Line(name: entry.name, needed: needed, owned: min(needed, owned[k] ?? 0)))
        }
        var match = CommanderMatch(slug: slug, name: name, rank: rank, numDecks: numDecks, lines: lines)
        match.commanderOwned = (owned[key(name)] ?? 0) > 0
        return match
    }
}

@MainActor
@Observable
final class CommanderFinder {
    static let shared = CommanderFinder()

    private(set) var period: EDHRECPeriod = .week
    /// Best match first.
    private(set) var matches: [CommanderMatch] = []
    private(set) var scanned = 0
    private(set) var total = 0
    private(set) var isScanning = false
    private(set) var error: String?
    private(set) var scannedAt: Date?

    private var task: Task<Void, Never>?
    private static let cache = DiskJSONCache(folder: "CommanderFinder")
    static let ttl: TimeInterval = 7 * 24 * 3600

    var progress: Double { total > 0 ? Double(scanned) / Double(total) : 0 }

    /// Scores the period's commanders against the collection. A scan in
    /// progress for the same period is left to finish; another period
    /// replaces it.
    func scan(period: EDHRECPeriod, container: ModelContainer, force: Bool = false) {
        if isScanning, period == self.period, !force { return }
        // A seeded run touches no network: the screen says so instead.
        if UITestSeed.isSeededRun {
            self.period = period
            error = "EDHREC couldn't be reached. Check the connection and try again."
            return
        }
        task?.cancel()
        self.period = period
        matches = []
        scanned = 0
        total = 0
        error = nil
        isScanning = true
        let rows = CollectionStore.shared(for: container)
        let decks = DeckStore.shared(for: container)
        let stamp = StoreStamp.current
        task = Task { [weak self] in
            do {
                let owned = try await Self.ownedCopies(rows, stamp: stamp)
                let list = try await Self.commanders(period: period, force: force)
                guard !Task.isCancelled else { return }
                self?.total = list.count
                for (i, commander) in list.enumerated() {
                    guard !Task.isCancelled else { return }
                    let slug = commander.sanitized ?? EDHRECClient.slug(for: commander.name)
                    let entries = try await Self.averageDeck(slug: slug, force: force)
                    let match = CommanderMatch.score(slug: slug, name: commander.name, rank: i + 1,
                                                     numDecks: commander.numDecks ?? 0, entries: entries, owned: owned)
                    guard let self, !Task.isCancelled else { return }
                    self.insert(match)
                    self.scanned = i + 1
                }
                // The commanders' own cards, for art, in one lookup.
                let names = list.map(\.name)
                let items = try await decks.items(names: names)
                guard let self, !Task.isCancelled else { return }
                self.matches = self.matches.map { match in
                    var m = match
                    if let item = items[match.name] {
                        m.artURL = item.artCropURL
                        m.imageURL = item.imageURL
                        m.scryfallID = item.scryfallID
                    }
                    return m
                }
                self.scannedAt = Date()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self?.error = Self.describe(error)
            }
            self?.isScanning = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isScanning = false
    }

    private func insert(_ match: CommanderMatch) {
        let at = matches.firstIndex { $0.share < match.share || ($0.share == match.share && $0.rank > match.rank) } ?? matches.count
        matches.insert(match, at: at)
    }

    private static func describe(_ error: Error) -> String {
        if let http = error as? HTTPError, case .rateLimited = http { return "EDHREC asked us to slow down. Try again in a minute." }
        return "EDHREC couldn't be reached. Check the connection and try again."
    }

    // MARK: Off the main actor

    /// Owned copies by front name across the real collections.
    @concurrent
    private nonisolated static func ownedCopies(_ rows: CollectionStore, stamp: StoreStamp) async throws -> [String: Int] {
        let cards = try await rows.ownedCards(stamp: stamp)
        var out: [String: Int] = [:]
        for card in cards { out[CommanderMatch.key(card.name), default: 0] += max(0, card.quantity) }
        return out
    }

    @concurrent
    private nonisolated static func commanders(period: EDHRECPeriod, force: Bool) async throws -> [EDHRECCardView] {
        let key = "top:\(period.rawValue)"
        if !force, let cached = await cache.value([EDHRECCardView].self, key: key, ttl: ttl) { return cached }
        let page = try await EDHRECClient.shared.topCommanders(period: period)
        let views = page.cardlists.first?.cardviews ?? []
        await cache.store(views, key: key)
        return views
    }

    @concurrent
    private nonisolated static func averageDeck(slug: String, force: Bool) async throws -> [EDHRECAverageDeck.Entry] {
        let key = "avg:\(slug)"
        if !force, let cached = await cache.value([EDHRECAverageDeck.Entry].self, key: key, ttl: ttl) { return cached }
        let entries: [EDHRECAverageDeck.Entry]
        do {
            entries = try await EDHRECClient.shared.averageDeck(slug: slug).entries
        } catch let error as HTTPError {
            // An unknown page is "no average deck", not a failed scan.
            if case .badStatus(let code, _) = error, code == 403 || code == 404 { entries = [] } else { throw error }
        }
        await cache.store(entries, key: key)
        return entries
    }
}
