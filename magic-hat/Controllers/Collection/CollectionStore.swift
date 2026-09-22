//
//  CollectionStore.swift
//  magic-hat
//
//  All heavy reads of the collection go through here, on a background
//  ModelActor context, and come back as plain Sendable values. That is what
//  lets a navigation push animate immediately: the view shows a placeholder
//  and the 3,900-row fetch + map + sort happens off the main thread.
//
//  It exists because the alternative — @Query in the view — runs its fetch
//  synchronously on the main thread during the first render, which is
//  exactly when the push transition is trying to animate.
//

import Foundation
import SwiftData

nonisolated struct CollectionSnapshot: Sendable {
    let items: [CardItem]
    /// Scryfall ids with no fetched metadata yet.
    let pendingIDs: [String]
    /// Fetched, but prices older than DataPolicy.priceTTL.
    let stalePriceIDs: [String]

    static let empty = CollectionSnapshot(items: [], pendingIDs: [], stalePriceIDs: [])
}

@ModelActor
actor CollectionStore {
    // One store per container so repeated reads share a row cache.
    @MainActor private static var instances: [ObjectIdentifier: CollectionStore] = [:]

    @MainActor
    static func shared(for container: ModelContainer) -> CollectionStore {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let store = CollectionStore(modelContainer: container)
        instances[key] = store
        return store
    }

    /// "deck:<uuid>" -> "Deck: Name", for rows that live in a deck.
    private func deckLabels() throws -> [String: String] {
        let decks = try modelContext.fetch(FetchDescriptor<Deck>())
        return Dictionary(decks.map { ($0.collectionKey, "Deck: \($0.name)") }, uniquingKeysWith: { a, _ in a })
    }

    /// Every card in a collection, sorted, plus what still needs fetching.
    func snapshot(collectionName: String, sort: CardSort) throws -> CollectionSnapshot {
        var descriptor = FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.collectionName == collectionName }
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)

        let cutoff = Date().addingTimeInterval(-DataPolicy.priceTTL)
        var items: [CardItem] = []
        items.reserveCapacity(entries.count)
        var pending = Set<String>()
        var stale = Set<String>()

        for entry in entries {
            let meta = entry.card
            items.append(CardItem(entry: entry, meta: meta))
            // A row stored before colours were kept counts as pending so the
            // collection filters get their data on the next hydration.
            if let meta, meta.fetchState == .fetched, meta.colorsRaw != nil {
                if (meta.pricesUpdatedAt ?? .distantPast) < cutoff { stale.insert(entry.scryfallID) }
            } else {
                pending.insert(entry.scryfallID)
            }
        }

        return CollectionSnapshot(
            items: CardSorting.sorted(items, by: sort),
            pendingIDs: Array(pending),
            stalePriceIDs: Array(stale)
        )
    }

    /// The audit ledger grouped by action, newest first. The ledger grows
    /// with every import; a @Query over it re-fetched the whole table on
    /// the main thread after every background save.
    func history() throws -> [HistoryAction] {
        var descriptor = FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.propertiesToFetch = [\.actionID, \.timestamp, \.quantityDelta, \.collectionName, \.binderName, \.actionRaw]
        let records = try modelContext.fetch(descriptor)
        let grouped = Dictionary(grouping: records, by: \.actionID)
        return grouped.values.map { recs -> HistoryAction in
            let added = recs.filter { $0.quantityDelta > 0 }.reduce(0) { $0 + $1.quantityDelta }
            let removed = recs.filter { $0.quantityDelta < 0 }.reduce(0) { $0 + $1.quantityDelta }
            var scopes = Set(recs.map(\.collectionName))
            scopes.formUnion(recs.map(\.binderName).filter { !$0.isEmpty })
            return HistoryAction(
                actionID: recs[0].actionID,
                timestamp: recs.map(\.timestamp).max() ?? .distantPast,
                added: added,
                removed: -removed,
                scopes: scopes.sorted(),
                action: recs[0].action
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    /// Per-collection totals and top cards for the Collections tab.
    func summaries() throws -> [CollectionSummary] {
        let collections = try modelContext.fetch(
            FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)])
        )
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)
        let byCollection = Dictionary(grouping: entries, by: \.collectionName)

        return collections.map { collection in
            let rows = byCollection[collection.name] ?? []
            var total = 0.0
            var valued: [(value: Double, entry: CollectionEntry)] = []
            for row in rows {
                let unit = row.finish == .normal
                    ? row.card?.priceUSD
                    : (row.card?.priceUSDFoil ?? row.card?.priceUSD)
                let value = (unit ?? 0) * Double(row.quantity)
                total += value
                if value > 0 { valued.append((value, row)) }
            }
            let top = valued.sorted { $0.value > $1.value }.prefix(5).map {
                CollectionSummary.Highlight(
                    id: $0.entry.id.uuidString,
                    imageURL: $0.entry.card?.imageNormalURL,
                    aspectRatio: $0.entry.card?.aspectRatio ?? (488.0 / 680.0)
                )
            }
            return CollectionSummary(
                name: collection.name,
                uniqueCards: rows.count,
                totalCopies: rows.reduce(0) { $0 + $1.quantity },
                totalValue: total,
                highlights: Array(top)
            )
        }
    }

    /// Every Scryfall id owned in any collection (for "in binder" markers).
    func ownedScryfallIDs() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.scryfallID]
        return Set(try modelContext.fetch(descriptor).map(\.scryfallID))
    }

    /// Scryfall ids of every printing we know for an oracle id.
    func printingIDs(oracleID: String) throws -> [String] {
        var descriptor = FetchDescriptor<CardMeta>(predicate: #Predicate { $0.oracleID == oracleID })
        descriptor.propertiesToFetch = [\.scryfallID]
        return try modelContext.fetch(descriptor).map(\.scryfallID)
    }

    /// Owned rows for any of the given printings, across all collections.
    func ownedItems(scryfallIDs: [String]) throws -> [CardItem] {
        let ids = scryfallIDs
        var descriptor = FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { ids.contains($0.scryfallID) },
            sortBy: [SortDescriptor(\.collectionName), SortDescriptor(\.setCode), SortDescriptor(\.collectorNumber)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let labels = try deckLabels()
        return try modelContext.fetch(descriptor).map { entry in
            var item = CardItem(entry: entry, meta: entry.card)
            if let label = labels[entry.collectionName] { item.collectionDisplayName = label }
            return item
        }
    }

    /// Names of all collections, sorted.
    func collectionNames() throws -> [String] {
        try modelContext.fetch(FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)])).map(\.name)
    }

    /// Collection names present on entries (for backfilling MTGCollection rows).
    func entryCollectionNames() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.collectionName]
        return Set(try modelContext.fetch(descriptor).map(\.collectionName)).filter { !$0.isEmpty }
    }
}
