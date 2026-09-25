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

/// Backed by its own serial queue, not `@ModelActor`'s default executor:
/// `DefaultSerialModelExecutor` runs each job on whatever thread awaited
/// it, so a store called from a view fetched and sorted *on the main
/// thread* (measured: 0.47s hangs in `snapshot` while pushing into a
/// 4k-card collection during a catalog ingest — the "off-main" reads were
/// only off-main when a detached task happened to call them). With the
/// queue as the actor's executor every job lands there, whoever calls.
actor CollectionStore: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private nonisolated let queue = DispatchSerialQueue(label: "magic-hat.collection-store", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }

    /// Snapshots by "collection|sort", built alongside the overview at
    /// launch so the first tap into a collection is a lookup, not a second
    /// full fetch queued behind the first. Each carries the StoreStamp it
    /// was built under; a caller whose stamp moved on (a write, a hydration
    /// batch) gets a fresh fetch, deterministically — no invalidation
    /// message to race against.
    private var snapshots: [String: (stamp: StoreStamp, snapshot: CollectionSnapshot)] = [:]

    private func cached(_ key: String, _ stamp: StoreStamp?) -> CollectionSnapshot? {
        guard let stamp, let entry = snapshots[key], entry.stamp == stamp else { return nil }
        return entry.snapshot
    }

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
    /// `CollectionScope.allKey` means every row in the store, decks
    /// included, each labelled with where it lives.
    /// Pass the caller's `stamp` to use (and fill) the cache; without one
    /// the fetch is always fresh, which is what tests want.
    func snapshot(collectionName: String, sort: CardSort, stamp: StoreStamp? = nil) throws -> CollectionSnapshot {
        let key = "\(collectionName)|\(sort.rawValue)"
        if let hit = cached(key, stamp) { return hit }
        let all = CollectionScope.isAll(collectionName)
        var descriptor = all
            ? FetchDescriptor<CollectionEntry>()
            : FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == collectionName })
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)
        let labels = all ? try deckLabels() : [:]
        let snapshot = Self.snapshot(of: entries, labels: labels, sort: sort)
        if let stamp { snapshots[key] = (stamp, snapshot) }
        return snapshot
    }

    private static func snapshot(of entries: [CollectionEntry], labels: [String: String], sort: CardSort) -> CollectionSnapshot {
        let cutoff = Date().addingTimeInterval(-DataPolicy.priceTTL)
        var items: [CardItem] = []
        items.reserveCapacity(entries.count)
        var pending = Set<String>()
        var stale = Set<String>()

        for entry in entries {
            let meta = entry.card
            var item = CardItem(entry: entry, meta: meta)
            if let label = labels[entry.collectionName] { item.collectionDisplayName = label }
            items.append(item)
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

    /// Per-collection totals and top cards (the Add sheet's picker).
    func summaries() throws -> [CollectionSummary] {
        try overview().collections
    }

    /// Builds and caches every collection's snapshot (and All Collection's)
    /// in `sort`, so the tap that follows the tab is a lookup. Its own call
    /// rather than part of `overview`: the totals are cheap and the tab
    /// wants them first; the sorts are the slow part and can land after.
    func prewarmSnapshots(sort: CardSort, stamp: StoreStamp) throws {
        let collections = try modelContext.fetch(FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)]))
        let key = "\(CollectionScope.allKey)|\(sort.rawValue)"
        if let cached = snapshots[key], cached.stamp == stamp,
           collections.allSatisfy({ snapshots["\($0.name)|\(sort.rawValue)"]?.stamp == stamp }) { return }
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)
        let byCollection = Dictionary(grouping: entries, by: \.collectionName)
        let labels = try deckLabels()
        for collection in collections {
            snapshots["\(collection.name)|\(sort.rawValue)"] =
                (stamp, Self.snapshot(of: byCollection[collection.name] ?? [], labels: [:], sort: sort))
        }
        snapshots[key] = (stamp, Self.snapshot(of: entries, labels: labels, sort: sort))
    }

    /// The Collections tab: every collection, the whole library, and the
    /// share of it built into decks — one pass over the entries. With a
    /// `sort`, the same pass also builds and caches every collection's
    /// snapshot (and All Collection's), so the tap that follows is instant
    /// (the tab asks for the totals first and prewarms afterwards).
    func overview(prewarming sort: CardSort? = nil, stamp: StoreStamp? = nil) throws -> CollectionOverview {
        let collections = try modelContext.fetch(
            FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)])
        )
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let entries = try modelContext.fetch(descriptor)
        let byCollection = Dictionary(grouping: entries, by: \.collectionName)

        if let sort, let stamp {
            let labels = try deckLabels()
            for collection in collections {
                snapshots["\(collection.name)|\(sort.rawValue)"] =
                    (stamp, Self.snapshot(of: byCollection[collection.name] ?? [], labels: [:], sort: sort))
            }
            snapshots["\(CollectionScope.allKey)|\(sort.rawValue)"] =
                (stamp, Self.snapshot(of: entries, labels: labels, sort: sort))
        }

        let perCollection = collections.map { Self.summary(name: $0.name, rows: byCollection[$0.name] ?? []) }
        let all = Self.summary(name: CollectionScope.allName, rows: entries)
        var deckCopies = 0
        var deckValue = 0.0
        for (name, rows) in byCollection where Deck.isDeckCollection(name) {
            for row in rows {
                deckCopies += row.quantity
                deckValue += Self.value(of: row)
            }
        }
        return CollectionOverview(collections: perCollection, all: all, deckCopies: deckCopies, deckValue: deckValue)
    }

    private static func value(of row: CollectionEntry) -> Double {
        let unit = row.finish == .normal
            ? row.card?.priceUSD
            : (row.card?.priceUSDFoil ?? row.card?.priceUSD)
        return (unit ?? 0) * Double(row.quantity)
    }

    private static func summary(name: String, rows: [CollectionEntry]) -> CollectionSummary {
        var total = 0.0
        var valued: [(value: Double, entry: CollectionEntry)] = []
        for row in rows {
            let value = value(of: row)
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
            name: name,
            uniqueCards: rows.count,
            totalCopies: rows.reduce(0) { $0 + $1.quantity },
            totalValue: total,
            highlights: Array(top)
        )
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

    /// Every set code on an owned row — what the set-symbol fallback would
    /// have to draw.
    func entrySetCodes() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.setCode]
        return Set(try modelContext.fetch(descriptor).map { $0.setCode.lowercased() })
    }

    /// Collection names present on entries (for backfilling MTGCollection
    /// rows). A deck's hidden collection is not one: backfilling it would
    /// have listed "deck:<uuid>" on the Collections tab.
    func entryCollectionNames() throws -> Set<String> {
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.propertiesToFetch = [\.collectionName]
        return Set(try modelContext.fetch(descriptor).map(\.collectionName))
            .filter { !$0.isEmpty && !Deck.isDeckCollection($0) }
    }
}

/// What a cached snapshot is valid for: the collection change revision and
/// the hydration revision at the time it was built. Views read both on the
/// main actor and hand the stamp to the store.
nonisolated struct StoreStamp: Hashable, Sendable {
    let change: Int
    let hydration: Int

    @MainActor static var current: StoreStamp {
        StoreStamp(change: CollectionChangeTracker.shared.revision, hydration: CardHydrationController.shared.revision)
    }
}
