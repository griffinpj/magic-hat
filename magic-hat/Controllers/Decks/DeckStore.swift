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

/// Own serial queue as executor — see CollectionStore for why.
actor DeckStore: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private nonisolated let queue = DispatchSerialQueue(label: "magic-hat.deck-store", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Where ownership comes from: the rows CollectionStore has built for
    /// the current stamp (usually already there — the Collections tab reads
    /// them first). Nil for a store made on its own (tests), which counts
    /// for itself on every call.
    private let rows: CollectionStore?

    init(modelContainer: ModelContainer, rows: CollectionStore? = nil) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
        self.rows = rows
    }

    @MainActor private static var instances: [ObjectIdentifier: DeckStore] = [:]

    @MainActor
    static func shared(for container: ModelContainer) -> DeckStore {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let store = DeckStore(modelContainer: container, rows: CollectionStore.shared(for: container))
        instances[key] = store
        return store
    }

    // MARK: Overview

    func overview() async throws -> [DeckSummary] {
        // One count of the collection for every tile, not one per deck.
        let owned = try await ownedIndex()
        let decks = try modelContext.fetch(FetchDescriptor<Deck>(sortBy: [SortDescriptor(\.updatedDate, order: .reverse)]))
        return try decks.map { deck in
            let snapshot = try snapshot(of: deck, owned: owned)
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

    func snapshot(deckID: UUID) async throws -> DeckSnapshot? {
        let owned = try await ownedIndex()
        guard let deck = try fetchDeck(deckID) else { return nil }
        return try snapshot(of: deck, owned: owned)
    }

    private func fetchDeck(_ id: UUID) throws -> Deck? {
        try modelContext.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
    }

    private func snapshot(of deck: Deck, owned: OwnedIndex) throws -> DeckSnapshot {
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
        // Copies still in collections, from the ownership index. Each
        // snapshot used to read every collection row and its CardMeta for
        // this — 0.4s of opening a deck on a real collection (debug build),
        // before the list could show, and again for every tile of the tab.
        var availableByKey = owned.copiesByKey.filter { matchKeys.contains($0.key) }

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
    func resolve(_ lines: [DeckListLine]) async throws -> [ResolvedDeckLine] {
        let owned = try await ownedIndex().scryfallIDs
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

    /// Every card in the real collections, one item per row, for searching
    /// the collection from a deck (grouped by card in the view).
    func ownedCards() throws -> [CardItem] {
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: #Predicate { !$0.collectionName.starts(with: "deck:") })
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        return try modelContext.fetch(descriptor).map { CardItem(entry: $0, meta: $0.card) }
    }

    // MARK: Cards for the analysis and the synergy screen

    /// Who owns what across the real collections: CollectionStore's
    /// count over the rows it holds for the current stamp — read on the
    /// main actor, where the trackers live — or, for a store made on its
    /// own, one pass here. Every consumer on this queue (the deck screen,
    /// each tile of the tab, the analysis and synergy lookups) used to make
    /// its own pass over every row and its CardMeta.
    func ownedIndex() async throws -> OwnedIndex {
        if let rows {
            let stamp = await MainActor.run { StoreStamp.current }
            return try await rows.ownedIndex(stamp: stamp)
        }
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: #Predicate { !$0.collectionName.starts(with: "deck:") })
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        var ids = Set<String>()
        var byKey: [String: Int] = [:]
        for entry in try modelContext.fetch(descriptor) {
            ids.insert(entry.scryfallID)
            byKey[entry.card?.oracleID ?? entry.scryfallID, default: 0] += entry.quantity
        }
        return OwnedIndex(scryfallIDs: ids, copiesByKey: byKey)
    }

    /// Copies owned per card key (oracle id, else Scryfall id) across the
    /// real collections — decks' hidden collections excluded.
    func ownedCopiesByKey() async throws -> [String: Int] {
        try await ownedIndex().copiesByKey
    }

    /// The collection as candidates for a deck: one per card across every
    /// printing owned, copies summed, hydrated rows only (a row with no
    /// text cannot be read).
    func collectionCandidates() throws -> [DeckSearchResult] {
        Self.candidates(from: try ownedCards())
    }

    /// `collectionCandidates` over cards already read — the analysis hands
    /// it the rows CollectionStore holds for the Collections tab.
    nonisolated static func candidates(from cards: [CardItem]) -> [DeckSearchResult] {
        var byKey: [String: DeckSearchResult] = [:]
        for item in cards where item.oracleText != nil || item.typeLine != nil {
            let key = item.oracleID ?? item.scryfallID
            if let existing = byKey[key] {
                byKey[key] = DeckSearchResult(card: existing.card, ownedCopies: existing.ownedCopies + item.quantity)
            } else {
                byKey[key] = DeckSearchResult(card: item, ownedCopies: item.quantity)
            }
        }
        return Array(byKey.values)
    }

    /// Catalog cards by Scryfall id, in the order asked (ids the catalog
    /// lacks are skipped). `owned` says whether any printing is in a
    /// collection.
    func items(scryfallIDs: [String]) async throws -> [CardItem] {
        let owned = try await ownedIndex().copiesByKey
        let ids = scryfallIDs
        let metas = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { ids.contains($0.scryfallID) }))
        let byID = Dictionary(metas.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })
        return scryfallIDs.compactMap { id in
            guard let meta = byID[id] else { return nil }
            return CardItem(meta: meta, owned: (owned[meta.oracleID ?? meta.scryfallID] ?? 0) > 0)
        }
    }

    /// One catalog card per oracle id: the printing the collection owns
    /// when it owns one, else the first the catalog has. `oracleID` is
    /// optional and unindexed, and neither `contains($0.oracleID ?? "")`
    /// nor a force-unwrap survives SwiftData's SQL generation (the first
    /// raised inside CoreData), so ids with a known name are fetched by
    /// name and the rest one at a time — a table scan each, so callers
    /// pass names whenever they have them.
    func items(oracleIDs: [String], names: [String: String] = [:]) async throws -> [String: CardItem] {
        let owned = try await ownedIndex()
        let wanted = Set(oracleIDs)
        var metas: [CardMeta] = []
        let named = Array(Set(oracleIDs.compactMap { names[$0] }))
        if !named.isEmpty {
            metas.append(contentsOf: try catalogRows(names: named))
        }
        var found = Set(metas.compactMap(\.oracleID))
        for oracle in oracleIDs where !found.contains(oracle) {
            let one = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.oracleID == oracle }))
            if !one.isEmpty { found.insert(oracle); metas.append(contentsOf: one) }
        }
        return pick(metas.filter { $0.oracleID.map(wanted.contains) ?? false }, key: { $0.oracleID ?? "" }, owned: owned)
    }

    /// One catalog card per name, front faces included ("Bloomvine Regent"
    /// finds "Bloomvine Regent // …"), keyed by the name asked for.
    func items(names: [String]) async throws -> [String: CardItem] {
        let owned = try await ownedIndex()
        let metas = try catalogRows(names: names)
        let front = CardReading.frontName
        let byFront = pick(metas, key: { front($0.name) }, owned: owned)
        var out: [String: CardItem] = [:]
        for name in names { if let item = byFront[front(name)] { out[name] = item } }
        return out
    }

    /// Rows by exact name, then front faces for the names not found.
    private func catalogRows(names: [String]) throws -> [CardMeta] {
        let wanted = names
        var metas = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { wanted.contains($0.name) }))
        let foundNames = Set(metas.map(\.name))
        for name in names where !foundNames.contains(name) {
            let prefix = name + " //"
            metas.append(contentsOf: try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.name.starts(with: prefix) })))
        }
        return metas
    }

    private func pick(_ metas: [CardMeta], key: (CardMeta) -> String, owned index: OwnedIndex) -> [String: CardItem] {
        let ownedIDs = index.scryfallIDs
        let owned = index.copiesByKey
        var chosen: [String: CardMeta] = [:]
        for meta in metas {
            let k = key(meta)
            guard !k.isEmpty else { continue }
            if let current = chosen[k] {
                if !ownedIDs.contains(current.scryfallID), ownedIDs.contains(meta.scryfallID) { chosen[k] = meta }
            } else {
                chosen[k] = meta
            }
        }
        return chosen.mapValues { CardItem(meta: $0, owned: (owned[$0.oracleID ?? $0.scryfallID] ?? 0) > 0) }
    }
}

nonisolated extension CardItem {
    /// A catalog card (no owned row behind it): the same shape a search
    /// hit has, keyed by its Scryfall id.
    init(meta: CardMeta, owned: Bool) {
        self.id = meta.scryfallID
        self.scryfallID = meta.scryfallID
        self.oracleID = meta.oracleID
        self.name = meta.name
        self.setCode = meta.setCode
        self.setName = meta.setName
        self.collectorNumber = meta.collectorNumber
        self.rarity = meta.rarity
        self.quantity = 1
        self.finish = .normal
        self.condition = "near_mint"
        self.language = "en"
        self.addedDate = nil
        self.owned = owned
        self.collectionName = ""
        self.imageURL = meta.imageNormalURL
        self.artCropURL = meta.artCropURL
        self.aspectRatio = meta.aspectRatio
        self.typeLine = meta.typeLine
        self.manaCost = meta.manaCost
        self.oracleText = meta.oracleText
        self.power = meta.power
        self.toughness = meta.toughness
        self.loyalty = meta.loyalty
        self.colors = Self.colors(fromLetters: meta.colorsRaw)
        self.colorIdentity = Self.colors(fromLetters: meta.colorIdentityRaw)
        self.artist = meta.artist
        self.priceUSD = meta.priceUSD
        self.priceUSDFoil = meta.priceUSDFoil
        self.sortKey = Self.sortKey(for: meta.name)
        self.collectorNumberValue = Self.collectorValue(meta.collectorNumber)
        self.rarityRankValue = Self.rarityRank(meta.rarity)
        self.purchasePrice = nil
        self.legalities = meta.legalities
        self.edhrecRank = meta.edhrecRank
        self.purchaseURIs = meta.purchaseURIs
    }
}
