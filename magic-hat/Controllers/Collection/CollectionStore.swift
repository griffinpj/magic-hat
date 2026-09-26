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

    /// Every owned row as a card, built once per stamp and shared by the
    /// overview, the backfill and every snapshot. Building them is the
    /// expensive part of any read: the first property read on each CardMeta
    /// fires its fault and materialises the whole model (0.25s for 3,900
    /// rows in a debug build), and the tab used to pay it three times per
    /// stamp — once to list the collection names for the backfill, once for
    /// the totals, once more for the sorted snapshots.
    private var rowsCache: (stamp: StoreStamp, rows: [Row])?

    nonisolated struct Row: Sendable {
        let item: CardItem
        /// No fetched metadata yet (or stored before colours were kept).
        let pending: Bool
        /// Fetched, but the prices are older than DataPolicy.priceTTL.
        let stale: Bool
    }

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
        try deckNames().mapValues { "Deck: \($0)" }
    }

    /// "deck:<uuid>" -> "Name".
    private func deckNames() throws -> [String: String] {
        let decks = try modelContext.fetch(FetchDescriptor<Deck>())
        return Dictionary(decks.map { ($0.collectionKey, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// Every owned row, decks included, each labelled with where it lives.
    /// Cached for `stamp`; without one (tests) always fresh.
    private func allRows(stamp: StoreStamp?) throws -> [Row] {
        if let stamp, let cache = rowsCache, cache.stamp == stamp { return cache.rows }
        var descriptor = FetchDescriptor<CollectionEntry>()
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        let rows = Self.rows(of: try modelContext.fetch(descriptor), labels: try deckLabels())
        if let stamp { rowsCache = (stamp, rows) }
        return rows
    }

    private static func rows(of entries: [CollectionEntry], labels: [String: String]) -> [Row] {
        let cutoff = Date().addingTimeInterval(-DataPolicy.priceTTL)
        var rows: [Row] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let meta = entry.card
            var item = CardItem(entry: entry, meta: meta)
            if let label = labels[entry.collectionName] { item.collectionDisplayName = label }
            // A row stored before colours were kept counts as pending so the
            // collection filters get their data on the next hydration.
            let fetched = meta.map { $0.fetchState == .fetched && $0.colorsRaw != nil } ?? false
            let stale = fetched && (meta?.pricesUpdatedAt ?? .distantPast) < cutoff
            rows.append(Row(item: item, pending: !fetched, stale: stale))
        }
        return rows
    }

    /// Every card in a collection, sorted, plus what still needs fetching.
    /// `CollectionScope.allKey` means every row in the store, decks
    /// included, each labelled with where it lives.
    /// Pass the caller's `stamp` to use (and fill) the cache; without one
    /// the fetch is always fresh, which is what tests want.
    func snapshot(collectionName: String, sort: CardSort, stamp: StoreStamp? = nil) throws -> CollectionSnapshot {
        let key = "\(collectionName)|\(sort.rawValue)"
        if let hit = cached(key, stamp) { return hit }
        let rows: [Row]
        if CollectionScope.isAll(collectionName) {
            rows = try allRows(stamp: stamp)
        } else if let stamp, let cache = rowsCache, cache.stamp == stamp {
            rows = cache.rows.filter { $0.item.collectionName == collectionName }
        } else {
            // One collection, nothing shared to reuse: fetch just its rows.
            var descriptor = FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == collectionName })
            descriptor.relationshipKeyPathsForPrefetching = [\.card]
            rows = Self.rows(of: try modelContext.fetch(descriptor), labels: [:])
        }
        let snapshot = Self.snapshot(of: rows, sort: sort)
        if let stamp { snapshots[key] = (stamp, snapshot) }
        return snapshot
    }

    private static func snapshot(of rows: [Row], sort: CardSort) -> CollectionSnapshot {
        var pending = Set<String>()
        var stale = Set<String>()
        for row in rows {
            if row.pending { pending.insert(row.item.scryfallID) }
            if row.stale { stale.insert(row.item.scryfallID) }
        }
        return CollectionSnapshot(
            items: CardSorting.sorted(rows.map(\.item), by: sort),
            pendingIDs: Array(pending),
            stalePriceIDs: Array(stale)
        )
    }

    /// The audit ledger grouped by action, newest first, each user action
    /// with where it stands in the undo/redo timeline (HistoryTimeline) and
    /// named for the cards it touched. The ledger grows with every import;
    /// a @Query over it re-fetched the whole table on the main thread after
    /// every background save.
    func history() throws -> HistoryLog {
        var descriptor = FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.propertiesToFetch = [\.actionID, \.timestamp, \.quantityDelta, \.collectionName, \.binderName,
                                        \.actionRaw, \.undoesActionID, \.scryfallID, \.cardName]
        let records = try modelContext.fetch(descriptor)
        let names = try deckNames()
        let grouped = Dictionary(grouping: records, by: \.actionID)
        var steps: [HistoryStep] = []
        steps.reserveCapacity(grouped.count)
        for (id, recs) in grouped {
            steps.append(HistoryStep(id: id, kind: recs[0].action, target: recs[0].undoesActionID,
                                     timestamp: recs.map(\.timestamp).min() ?? .distantPast))
        }
        let timeline = HistoryTimeline.resolve(steps)
        var actions: [HistoryAction] = []
        for (id, recs) in grouped {
            let kind = recs[0].action
            guard kind.isUserAction else { continue }
            let added = recs.filter { $0.quantityDelta > 0 }.reduce(0) { $0 + $1.quantityDelta }
            let removed = recs.filter { $0.quantityDelta < 0 }.reduce(0) { $0 + $1.quantityDelta }
            var scopes = Set<String>()
            var deckName: String?
            for record in recs {
                let name = record.collectionName
                if let deck = names[name] {
                    scopes.insert("Deck: \(deck)")
                    deckName = deck
                } else if Deck.isDeckCollection(name) {
                    scopes.insert("Deleted deck")
                } else {
                    scopes.insert(name)
                }
                if !record.binderName.isEmpty { scopes.insert(record.binderName) }
            }
            // The cards, largest change first, by printing.
            var copies: [String: (name: String, copies: Int)] = [:]
            for record in recs {
                copies[record.scryfallID, default: (record.cardName, 0)].copies += abs(record.quantityDelta)
            }
            let ranked = copies.values.sorted { a, b in
                if a.copies != b.copies { return a.copies > b.copies }
                return a.name < b.name
            }
            var seen = Set<String>()
            let cardNames = ranked.compactMap { seen.insert($0.name).inserted ? $0.name : nil }.prefix(3)
            actions.append(HistoryAction(
                actionID: id,
                timestamp: recs.map(\.timestamp).max() ?? .distantPast,
                added: added,
                removed: -removed,
                scopes: scopes.sorted(),
                action: kind,
                state: timeline.state(of: id),
                cardCount: copies.count,
                cardNames: Array(cardNames),
                deckName: deckName,
                replaced: recs.contains { $0.action == .importReplace }
            ))
        }
        actions.sort { $0.timestamp > $1.timestamp }
        return HistoryLog(actions: actions, timeline: timeline)
    }

    /// One action's changes, merged per printing and grouped by the
    /// collection they landed in — or, for a build or disassembly, by the
    /// move (source → destination), each card once. Every group is sorted
    /// largest change first and carries the full count; the screen caps
    /// what it shows. Art comes from CardMeta when the card is cached.
    func historyDetail(actionID: UUID) throws -> HistoryDetail {
        let records = try modelContext.fetch(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.actionID == actionID }))
        let deckNames = try deckNames()
        func plain(_ collection: String) -> String {
            deckNames[collection] ?? (Deck.isDeckCollection(collection) ? "a deleted deck" : collection)
        }
        func label(_ collection: String) -> String {
            deckNames[collection].map { "Deck: \($0)" } ?? (Deck.isDeckCollection(collection) ? "Deleted deck" : collection)
        }

        // Metadata for the printing line and the art, where cached.
        var metas: [String: CardMeta] = [:]
        for chunk in Array(Set(records.map(\.scryfallID))).chunked(into: 500) {
            for meta in try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                metas[meta.scryfallID] = meta
            }
        }

        // Merge the records per printing and collection.
        struct Key: Hashable { let collection: String; let card: String; let finish: String; let condition: String }
        var merged: [Key: (record: AuditRecord, delta: Int)] = [:]
        for record in records {
            let key = Key(collection: record.collectionName, card: record.scryfallID, finish: record.finishRaw, condition: record.condition)
            merged[key, default: (record, 0)].delta += record.quantityDelta
        }
        func change(_ record: AuditRecord, delta: Int, id: String) -> HistoryChange {
            let meta = metas[record.scryfallID]
            return HistoryChange(
                id: id, scryfallID: record.scryfallID, name: record.cardName,
                setCode: record.setCode ?? meta?.setCode ?? "",
                collectorNumber: record.collectorNumber ?? meta?.collectorNumber ?? "",
                rarity: record.rarity ?? meta?.rarity,
                finish: record.finish, condition: record.condition, delta: delta,
                artCropURL: meta?.artCropURL, imageURL: meta?.imageNormalURL
            )
        }

        var groups: [String: (kind: HistoryChangeGroup.Kind, title: String, destination: String?, changes: [HistoryChange])] = [:]
        var order: [String] = []
        func append(_ change: HistoryChange, to id: String, kind: HistoryChangeGroup.Kind, title: String, destination: String? = nil) {
            if groups[id] == nil {
                groups[id] = (kind, title, destination, [])
                order.append(id)
            }
            groups[id]!.changes.append(change)
        }

        let kind = records.first?.action
        var leftover = merged
        if kind == .deckBuild || kind == .deckDisassemble {
            // A move: the same printing out of one collection and into
            // another by the same count, shown once.
            struct Printing: Hashable { let card: String; let finish: String; let condition: String }
            let byPrinting = Dictionary(grouping: merged.keys) { Printing(card: $0.card, finish: $0.finish, condition: $0.condition) }
            for (printing, keys) in byPrinting {
                let outs = keys.filter { merged[$0]!.delta < 0 }
                let ins = keys.filter { merged[$0]!.delta > 0 }
                guard outs.count == 1, ins.count == 1, let out = outs.first, let into = ins.first,
                      -merged[out]!.delta == merged[into]!.delta else { continue }
                let id = "\(out.collection)→\(into.collection)"
                append(change(merged[into]!.record, delta: merged[into]!.delta, id: "\(id)|\(printing.card)|\(printing.finish)|\(printing.condition)"),
                       to: id, kind: .move, title: plain(out.collection), destination: plain(into.collection))
                leftover[out] = nil
                leftover[into] = nil
            }
        }
        for (key, value) in leftover where value.delta != 0 {
            append(change(value.record, delta: value.delta, id: "\(key.collection)|\(key.card)|\(key.finish)|\(key.condition)"),
                   to: key.collection, kind: .scope, title: label(key.collection))
        }

        var built: [HistoryChangeGroup] = []
        for id in order {
            let group = groups[id]!
            let changes = group.changes.sorted { a, b in
                if abs(a.delta) != abs(b.delta) { return abs(a.delta) > abs(b.delta) }
                return a.name < b.name
            }
            var added = 0
            var removed = 0
            for change in changes {
                if change.delta > 0 { added += change.delta } else { removed -= change.delta }
            }
            built.append(HistoryChangeGroup(id: id, kind: group.kind, title: group.title, destination: group.destination,
                                            added: added, removed: removed, total: changes.count, changes: changes))
        }
        // Moves first, then whichever moved most.
        built.sort { a, b in
            if (a.kind == .move) != (b.kind == .move) { return a.kind == .move }
            if a.added + a.removed != b.added + b.removed { return a.added + a.removed > b.added + b.removed }
            return a.title < b.title
        }
        return HistoryDetail(actionID: actionID, groups: built)
    }

    /// Per-collection totals and top cards (the Add sheet's picker). With
    /// the caller's stamp, the rows the Collections tab read are reused.
    func summaries(stamp: StoreStamp? = nil) throws -> [CollectionSummary] {
        try overview(stamp: stamp).collections
    }

    /// Builds and caches every collection's snapshot (and All Collection's)
    /// in `sort`, so the tap that follows the tab is a lookup. Its own call
    /// rather than part of `overview`: the totals are what the tab draws
    /// and land first; the sorts follow, over the rows the overview built.
    func prewarmSnapshots(sort: CardSort, stamp: StoreStamp) throws {
        let names = try collectionNames()
        let keys = [CollectionScope.allKey] + names
        guard !keys.allSatisfy({ snapshots["\($0)|\(sort.rawValue)"]?.stamp == stamp }) else { return }
        let rows = try allRows(stamp: stamp)
        let byCollection = Dictionary(grouping: rows, by: \.item.collectionName)
        for name in names {
            snapshots["\(name)|\(sort.rawValue)"] = (stamp, Self.snapshot(of: byCollection[name] ?? [], sort: sort))
        }
        snapshots["\(CollectionScope.allKey)|\(sort.rawValue)"] = (stamp, Self.snapshot(of: rows, sort: sort))
    }

    /// The Collections tab: every collection, the whole library, the share
    /// of it built into decks, and the collection names found on rows (for
    /// the backfill) — one pass over rows shared with the snapshots.
    func overview(stamp: StoreStamp? = nil) throws -> CollectionOverview {
        let names = try collectionNames()
        let rows = try allRows(stamp: stamp)
        let byCollection = Dictionary(grouping: rows, by: \.item.collectionName)

        let perCollection = names.map { Self.summary(name: $0, rows: byCollection[$0] ?? []) }
        let all = Self.summary(name: CollectionScope.allName, rows: rows)
        var deckCopies = 0
        var deckValue = 0.0
        for (name, rows) in byCollection where Deck.isDeckCollection(name) {
            for row in rows {
                deckCopies += row.item.quantity
                deckValue += Self.value(of: row.item)
            }
        }
        let onRows = Set(byCollection.keys.filter { !$0.isEmpty && !Deck.isDeckCollection($0) })
        return CollectionOverview(collections: perCollection, all: all, deckCopies: deckCopies, deckValue: deckValue,
                                  entryCollectionNames: onRows)
    }

    private static func value(of item: CardItem) -> Double {
        (item.marketPrice ?? 0) * Double(item.quantity)
    }

    private static func summary(name: String, rows: [Row]) -> CollectionSummary {
        var total = 0.0
        var valued: [(value: Double, item: CardItem)] = []
        for row in rows {
            let value = value(of: row.item)
            total += value
            if value > 0 { valued.append((value, row.item)) }
        }
        let top = valued.sorted { $0.value > $1.value }.prefix(5).map {
            CollectionSummary.Highlight(id: $0.item.id, imageURL: $0.item.imageURL, aspectRatio: $0.item.aspectRatio)
        }
        return CollectionSummary(
            name: name,
            uniqueCards: rows.count,
            totalCopies: rows.reduce(0) { $0 + $1.item.quantity },
            totalValue: total,
            highlights: Array(top)
        )
    }

    /// Every card in the real collections — decks' rows left out — one item
    /// per row. With the caller's stamp these are the rows the Collections
    /// tab already built, so a deck's add sheet and its analysis don't read
    /// and fault the whole collection again on DeckStore's queue.
    func ownedCards(stamp: StoreStamp? = nil) throws -> [CardItem] {
        try allRows(stamp: stamp).compactMap { Deck.isDeckCollection($0.item.collectionName) ? nil : $0.item }
    }

    /// The real collections' printings and copies per card key (oracle id,
    /// else Scryfall id), decks' rows left out — what DeckStore counts
    /// "in collection" and "owned" by. Cached per stamp over the rows.
    func ownedIndex(stamp: StoreStamp? = nil) throws -> OwnedIndex {
        if let stamp, let cache = ownedIndexCache, cache.stamp == stamp { return cache.index }
        var ids = Set<String>()
        var byKey: [String: Int] = [:]
        for row in try allRows(stamp: stamp) where !Deck.isDeckCollection(row.item.collectionName) {
            ids.insert(row.item.scryfallID)
            byKey[row.item.oracleID ?? row.item.scryfallID, default: 0] += row.item.quantity
        }
        let index = OwnedIndex(scryfallIDs: ids, copiesByKey: byKey)
        if let stamp { ownedIndexCache = (stamp, index) }
        return index
    }
    private var ownedIndexCache: (stamp: StoreStamp, index: OwnedIndex)?

    /// Every Scryfall id owned in any collection (for "in binder" markers).
    /// From the rows when they are built for the caller's stamp; otherwise
    /// one plain fetch (a `propertiesToFetch` fetch measured slower here:
    /// SwiftData faults each partial row in as it is read).
    func ownedScryfallIDs(stamp: StoreStamp? = nil) throws -> Set<String> {
        if let stamp, let cache = rowsCache, cache.stamp == stamp { return Set(cache.rows.map(\.item.scryfallID)) }
        return Set(try modelContext.fetch(FetchDescriptor<CollectionEntry>()).map(\.scryfallID))
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

/// Who owns what, for the deck screens: see `CollectionStore.ownedIndex`.
nonisolated struct OwnedIndex: Sendable {
    let scryfallIDs: Set<String>
    let copiesByKey: [String: Int]
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
