//
//  DeckStore.swift
//  magic-hat
//
//  Reads for the Decks tab and the deck screen, on a background context:
//  the overview tiles, a deck's snapshot (list + build state + stats), and
//  resolving an imported list against the catalog. Nothing here touches
//  the main thread; results are Sendable values.
//

import Foundation
import SwiftData

@ModelActor
actor DeckStore {
    @MainActor private static var instances: [ObjectIdentifier: DeckStore] = [:]

    @MainActor
    static func shared(for container: ModelContainer) -> DeckStore {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let store = DeckStore(modelContainer: container)
        instances[key] = store
        return store
    }

    // MARK: Overview

    func overview() throws -> [DeckSummary] {
        let decks = try modelContext.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.updatedDate, order: .reverse)]))
        return try decks.map { deck in
            let snapshot = try snapshot(of: deck)
            return DeckSummary(
                id: deck.id, name: deck.name, format: deck.format,
                mainCopies: snapshot.mainCopies, builtCopies: snapshot.builtCopies,
                identity: snapshot.identity,
                coverArtURL: deck.coverArtURL ?? snapshot.commanders.first?.card.artCropURL ?? snapshot.sections.first?.items.first?.card.artCropURL,
                isLocked: deck.isLocked, totalValue: snapshot.stats.totalValue, updatedDate: deck.updatedDate
            )
        }
    }

    /// Deck ids and names, for labelling the hidden collections elsewhere.
    func deckNames() throws -> [String: String] {
        let decks = try modelContext.fetch(FetchDescriptor<Deck>())
        return Dictionary(decks.map { ($0.collectionKey, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Snapshot

    func snapshot(deckID: UUID) throws -> DeckSnapshot? {
        guard let deck = try fetchDeck(deckID) else { return nil }
        return try snapshot(of: deck)
    }

    private func fetchDeck(_ id: UUID) throws -> Deck? {
        try modelContext.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
    }

    private func snapshot(of deck: Deck) throws -> DeckSnapshot {
        let cards = deck.cards.sorted { a, b in
            if a.board != b.board { return boardOrder(a.board) < boardOrder(b.board) }
            return a.name < b.name
        }
        let ids = Array(Set(cards.map(\.scryfallID)))
        let metas = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { ids.contains($0.scryfallID) }))
        let metaByID = Dictionary(metas.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })

        // Physical copies: in the deck, and still in collections (any printing).
        let matchKeys = Set(cards.map { $0.oracleID ?? metaByID[$0.scryfallID]?.oracleID ?? $0.scryfallID })
        let key = deck.collectionKey
        var builtByKey = try quantities(where: #Predicate { $0.collectionName == key }, keys: matchKeys)
        var availableByKey = try quantities(
            where: #Predicate { !$0.collectionName.starts(with: "deck:") },
            keys: matchKeys
        )

        var items: [DeckCardItem] = []
        items.reserveCapacity(cards.count)
        for card in cards {
            let meta = metaByID[card.scryfallID]
            let matchKey = card.oracleID ?? meta?.oracleID ?? card.scryfallID
            let built = min(card.quantity, builtByKey[matchKey] ?? 0)
            builtByKey[matchKey, default: 0] -= built
            let available = min(max(0, card.quantity - built), availableByKey[matchKey] ?? 0)
            availableByKey[matchKey, default: 0] -= available
            items.append(DeckCardItem(
                id: card.id, board: card.board, quantity: card.quantity,
                card: CardItem(deckCard: card, meta: meta, quantity: card.quantity, owned: built + available > 0),
                builtQuantity: built, availableQuantity: available
            ))
        }

        let commanders = items.filter { $0.board == .commander }
        let main = items.filter { $0.board == .main }
        let identity: [ManaColor]
        if deck.format.hasCommander, !commanders.isEmpty {
            let set = Set(commanders.flatMap(\.card.colorIdentity))
            identity = ManaColor.allCases.filter { set.contains($0) }
        } else {
            let set = Set(main.flatMap(\.card.colors))
            identity = ManaColor.allCases.filter { set.contains($0) }
        }

        let grouped = Dictionary(grouping: main) { DeckStats.primaryType(of: $0.card.typeLine) }
        let sections = DeckStats.typeOrder.compactMap { type -> DeckSection? in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            let title = type == "Other" ? "Other" : type + "s"
            return DeckSection(id: type, title: title, glyph: DeckStats.glyph(forType: type),
                               items: group.sorted { ($0.card.name) < ($1.card.name) })
        }
        let played = commanders + main
        let stats = DeckStats.compute(played: played, format: deck.format, identity: identity, allItems: items)

        return DeckSnapshot(
            id: deck.id, name: deck.name, format: deck.format, isLocked: deck.isLocked, notes: deck.notes,
            createdDate: deck.createdDate, updatedDate: deck.updatedDate, identity: identity,
            commanders: commanders, sections: sections,
            sideboard: items.filter { $0.board == .side }, maybeboard: items.filter { $0.board == .maybe },
            stats: stats
        )
    }

    private func boardOrder(_ board: DeckBoard) -> Int {
        switch board {
        case .commander: return 0
        case .main: return 1
        case .side: return 2
        case .maybe: return 3
        }
    }

    /// Copies per match key (oracle id, else scryfall id) among entries
    /// matching `predicate`, restricted to the keys the deck cares about.
    private func quantities(where predicate: Predicate<CollectionEntry>, keys: Set<String>) throws -> [String: Int] {
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: predicate)
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)
        var out: [String: Int] = [:]
        for entry in entries {
            let key = entry.card?.oracleID ?? entry.scryfallID
            guard keys.contains(key) else { continue }
            out[key, default: 0] += entry.quantity
        }
        return out
    }

    // MARK: Resolving a list

    /// Matches parsed lines to the catalog: exact printing when the line
    /// names one, else by name — preferring a printing the collection owns,
    /// so the deck shows what the user actually holds. Double-faced cards
    /// match on their front face name.
    func resolve(_ lines: [DeckListLine]) throws -> [ResolvedDeckLine] {
        let names = Array(Set(lines.map(\.name)))
        let byName = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { names.contains($0.name) }))
        var metasByName: [String: [CardMeta]] = [:]
        for meta in byName { metasByName[meta.name, default: []].append(meta) }

        // Front-face names ("Bloomvine Regent" for "Bloomvine Regent // …").
        let unresolvedNames = names.filter { metasByName[$0] == nil }
        if !unresolvedNames.isEmpty {
            for name in unresolvedNames {
                let prefix = name + " //"
                let faces = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.name.starts(with: prefix) }))
                if !faces.isEmpty { metasByName[name] = faces }
            }
        }

        let sets = Array(Set(lines.compactMap(\.setCode)))
        let bySet = sets.isEmpty ? [] : try modelContext.fetch(
            FetchDescriptor<CardMeta>(predicate: #Predicate { sets.contains($0.setCode) })
        )
        let byPrinting = Dictionary(bySet.map { ("\($0.setCode)|\($0.collectorNumber)", $0) }, uniquingKeysWith: { a, _ in a })

        let owned = try ownedScryfallIDs()

        return lines.map { line in
            var meta: CardMeta?
            if let set = line.setCode, let number = line.collectorNumber {
                meta = byPrinting["\(set.lowercased())|\(number)"]
            }
            if meta == nil, let candidates = metasByName[line.name] {
                meta = candidates.first { owned.contains($0.scryfallID) } ?? candidates.first
            }
            return ResolvedDeckLine(line: line, scryfallID: meta?.scryfallID, oracleID: meta?.oracleID, canonicalName: meta?.name)
        }
    }

    private func ownedScryfallIDs() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: #Predicate { !$0.collectionName.starts(with: "deck:") })
        descriptor.propertiesToFetch = [\.scryfallID]
        return Set(try modelContext.fetch(descriptor).map(\.scryfallID))
    }

    /// Every card in the real collections, one item per row, for searching
    /// the collection from a deck (grouped by card in the view).
    func ownedCards() throws -> [CardItem] {
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: #Predicate { !$0.collectionName.starts(with: "deck:") })
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        return try modelContext.fetch(descriptor).map { CardItem(entry: $0, meta: $0.card) }
    }
}
