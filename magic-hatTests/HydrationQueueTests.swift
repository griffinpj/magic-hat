import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// What the hydration sync asks Scryfall for, and in which order: an id
/// Scryfall answered `not_found` for rests a day instead of going out on
/// every launch, and pending ids come in the grid's order so the first
/// screen fills first.
@MainActor
@Suite("Hydration queue", .serialized)
struct HydrationQueueTests {
    private func addRow(_ id: String, name: String, price: Double? = nil, state: CardFetchState = .pending,
                        lastFetched: Date? = nil, in ctx: ModelContext) {
        let meta = CardMeta(scryfallID: id, name: name, fetchState: state)
        meta.lastFetched = lastFetched
        meta.priceUSD = price
        ctx.insert(meta)
        let entry = CollectionEntry(scryfallID: id, collectionName: "Main", name: name)
        entry.card = meta
        ctx.insert(entry)
    }

    @Test func notFoundRestsADayThenComesBack() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        addRow("gone", name: "Gone", in: ctx)
        addRow("flaky", name: "Flaky", in: ctx)
        addRow("old", name: "Old", state: .failed,
               lastFetched: Date().addingTimeInterval(-CardMetaWriter.notFoundBackoff - 60), in: ctx)
        try ctx.save()

        let writer = CardMetaWriter.shared(for: container)
        try await writer.markFailed(["gone"], notFound: true)
        try await writer.markFailed(["flaky"])      // a failed request, not an answer

        let needed = await writer.neededIDs(from: ["gone", "flaky", "old"])
        #expect(needed == ["flaky", "old"], "not_found today rests; a failed request and a day-old not_found are asked again")

        let store = CollectionStore.shared(for: container)
        let snapshot = try await store.snapshot(collectionName: "Main", sort: .name)
        #expect(Set(snapshot.pendingIDs) == ["flaky", "old"])
        let due = try await store.dueForRefresh()
        #expect(Set(due.pending) == ["flaky", "old"], "the app-level sync leaves it alone too")
        #expect(!due.stale.contains("gone"))

        let gone = try #require(try ModelContext(container).fetch(FetchDescriptor<CardMeta>(
            predicate: #Predicate { $0.scryfallID == "gone" })).first)
        #expect(gone.fetchState == .failed && gone.lastFetched != nil)
    }

    @Test func pendingIDsFollowTheGridOrder() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        // Inserted out of order; the snapshot's sort is what counts.
        for (id, name) in [("d", "Delta"), ("a", "Alpha"), ("c", "Charlie"), ("b", "Bravo")] {
            addRow(id, name: name, in: ctx)
        }
        let fetched = CardMeta(scryfallID: "e", name: "Echo", fetchState: .fetched)
        fetched.colorsRaw = ""
        fetched.metaVersion = CardMeta.currentVersion
        ctx.insert(fetched)
        let entry = CollectionEntry(scryfallID: "e", collectionName: "Main", name: "Echo")
        entry.card = fetched
        ctx.insert(entry)
        try ctx.save()

        let store = CollectionStore.shared(for: container)
        let byName = try await store.snapshot(collectionName: "Main", sort: .name)
        #expect(byName.pendingIDs == ["a", "b", "c", "d"])
        let reversed = try await store.snapshot(collectionName: "Main", sort: .name, direction: .descending)
        #expect(reversed.pendingIDs == ["d", "c", "b", "a"])

        // The merge read: the same cards, unsorted.
        let current = try await store.currentItems(collectionName: "Main")
        #expect(Set(current.map(\.scryfallID)) == ["a", "b", "c", "d", "e"])
    }

    /// The cache keeps one stamp's worth: a read under a newer stamp is
    /// fresh and an older stamp's entries are gone (a read under it is
    /// fresh again, not the old snapshot).
    @Test func snapshotCacheKeepsOnlyTheLatestStamp() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        addRow("a", name: "Alpha", in: ctx)
        try ctx.save()
        let store = CollectionStore.shared(for: container)
        let first = StoreStamp(change: 1, hydration: 0)
        _ = try await store.snapshot(collectionName: "Main", sort: .name, stamp: first)

        addRow("b", name: "Bravo", in: ctx)
        try ctx.save()
        let cachedRead = try await store.snapshot(collectionName: "Main", sort: .name, stamp: first)
        #expect(cachedRead.items.count == 1, "same stamp: served from the cache")

        let second = StoreStamp(change: 2, hydration: 0)
        #expect(try await store.snapshot(collectionName: "Main", sort: .price, stamp: second).items.count == 2)
        // Writing under the second stamp dropped the first's entries.
        #expect(try await store.snapshot(collectionName: "Main", sort: .name, stamp: first).items.count == 2)
    }
}
