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
            if let meta, meta.fetchState == .fetched {
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

    /// Collection names present on entries (for backfilling MTGCollection rows).
    func entryCollectionNames() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.collectionName]
        return Set(try modelContext.fetch(descriptor).map(\.collectionName)).filter { !$0.isEmpty }
    }
}
