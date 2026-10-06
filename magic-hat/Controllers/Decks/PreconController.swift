//
//  PreconController.swift
//  magic-hat
//
//  Preconstructed decks, from MTGJSON — the one source with deck data
//  (Scryfall has none): `DeckList.json` (634KB, ~3,100 products) for the
//  list, `decks/<fileName>.json` (~570KB, every card in full) for one
//  deck. Both cached under Caches/Precons — the list a week, a deck a
//  month, since a printed deck never changes — and decoded off the main
//  actor. A singleton, so leaving the Precons page keeps the list.
//
//  Reading a deck for the screen is `DeckStore.preconSnapshot`: the
//  cards resolved through the catalog (the rest fetched from Scryfall
//  once), owned copies counted, nothing built, locked. Importing one is
//  `importDeck`: a new Deck with the list's rows, through the same path
//  a pasted list takes.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class PreconController {
    static let shared = PreconController()

    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var summaries: [MTGJSONDeckSummary] = []
    private(set) var loadedAt: Date?

    private static let cache = DiskJSONCache(folder: "Precons")
    private static let listKey = "deck-list"
    private static let listTTL: TimeInterval = 7 * 24 * 3600
    private static let deckTTL: TimeInterval = 30 * 24 * 3600

    /// Under `-uitest-seed` nothing is fetched (tests never touch the
    /// network); the page shows the offline error.
    var allowsNetwork = !ProcessInfo.processInfo.arguments.contains("-uitest-seed")

    func load(force: Bool = false) async {
        if phase == .loading { return }
        if phase == .loaded, !force { return }
        phase = .loading
        if !force, let cached = await Self.cache.value([MTGJSONDeckSummary].self, key: Self.listKey, ttl: Self.listTTL) {
            summaries = cached
            loadedAt = await Self.cache.fetchedAt(key: Self.listKey)
            phase = .loaded
            return
        }
        guard allowsNetwork else {
            phase = .failed("Preconstructed decks need a connection the first time.")
            return
        }
        do {
            let list = try await Self.fetchList()
            await Self.cache.store(list, key: Self.listKey)
            summaries = list
            loadedAt = Date()
            phase = .loaded
        } catch {
            // A stale list beats none.
            if let stale = await Self.cache.stale([MTGJSONDeckSummary].self, key: Self.listKey) {
                summaries = stale.value
                loadedAt = stale.fetchedAt
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    @concurrent
    private static func fetchList() async throws -> [MTGJSONDeckSummary] {
        try await MTGJSONClient.shared.deckList()
    }

    func summary(fileName: String) -> MTGJSONDeckSummary? {
        summaries.first { $0.fileName == fileName }
    }

    /// One deck, cached a month.
    func deck(fileName: String) async throws -> MTGJSONDeck {
        let key = "deck-\(fileName)"
        if let cached = await Self.cache.value(MTGJSONDeck.self, key: key, ttl: Self.deckTTL) { return cached }
        guard allowsNetwork else { throw PreconError.offline }
        let deck = try await Self.fetchDeck(fileName: fileName)
        await Self.cache.store(deck, key: key)
        return deck
    }

    @concurrent
    private static func fetchDeck(fileName: String) async throws -> MTGJSONDeck {
        try await MTGJSONClient.shared.deck(fileName: fileName)
    }

    /// The decks of `kind` whose name or code matches `filter`, grouped
    /// by release year, newest first; within a year by date then name.
    nonisolated static func sections(_ summaries: [MTGJSONDeckSummary], kind: PreconKind, filter: String) -> [PreconSection] {
        let needle = filter.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matching = summaries.filter { summary in
            guard kind.matches(summary.type) else { return false }
            guard !needle.isEmpty else { return true }
            let name = summary.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return name.contains(needle) || summary.code.lowercased().hasPrefix(needle)
                || (summary.type ?? "").lowercased().contains(needle)
        }
        let byYear = Dictionary(grouping: matching) { String(($0.releaseDate ?? "").prefix(4)) }
        return byYear.keys.sorted(by: >).map { year in
            let decks = byYear[year]!.sorted {
                if ($0.releaseDate ?? "") != ($1.releaseDate ?? "") { return ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
                return $0.name < $1.name
            }
            return PreconSection(year: year.isEmpty ? "Undated" : year, decks: decks)
        }
    }

    /// A new deck from the precon: its name and format, every row on its
    /// board, through the import path a pasted list takes (so the rows
    /// carry the printing and the deck is editable from here on).
    func importDeck(_ deck: MTGJSONDeck, context: ModelContext) throws -> UUID {
        let format = DeckStore.preconFormat(deck.type)
        let created = try DeckEditController.createDeck(name: deck.name, format: format, commander: nil, context: context)
        var lines: [ResolvedDeckLine] = []
        func add(_ cards: [MTGJSONDeckCard]?, board: DeckBoard) {
            for card in cards ?? [] {
                guard let id = card.scryfallID else { continue }
                let line = DeckListLine(quantity: card.count, name: card.name, setCode: card.setCode?.lowercased(),
                                        collectorNumber: card.number, isFoil: card.isFoil ?? false, board: board, raw: card.name)
                lines.append(ResolvedDeckLine(line: line, scryfallID: id, oracleID: card.identifiers.scryfallOracleId,
                                              canonicalName: card.name))
            }
        }
        add(deck.commander, board: .commander)
        add(deck.mainBoard, board: .main)
        add(deck.sideBoard, board: .side)
        _ = try DeckEditController.importLines(lines, into: created.id, context: context)
        return created.id
    }
}

nonisolated enum PreconError: LocalizedError {
    case offline
    var errorDescription: String? { "Preconstructed decks need a connection the first time." }
}

nonisolated struct PreconSection: Identifiable, Hashable, Sendable {
    let year: String
    let decks: [MTGJSONDeckSummary]
    var id: String { year }
}
