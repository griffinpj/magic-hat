import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("CollectionStore")
struct CollectionStoreTests {
    @Test @MainActor func snapshotSortsAndFlagsPendingAndStale() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))

        func add(_ id: String, name: String, state: CardFetchState, price: Double?, priceAge: TimeInterval) {
            let meta = CardMeta(scryfallID: id, name: name, fetchState: state)
            // A fetched row also carries colours; without them it counts as
            // pending (backfill for rows stored before colours were kept).
            if state == .fetched { meta.colorsRaw = "" }
            meta.priceUSD = price
            meta.pricesUpdatedAt = Date().addingTimeInterval(-priceAge)
            ctx.insert(meta)
            let entry = CollectionEntry(scryfallID: id, collectionName: "Main", name: name)
            entry.card = meta
            ctx.insert(entry)
        }
        add("fresh",   name: "Fresh",   state: .fetched, price: 20, priceAge: 60)
        add("stale",   name: "Stale",   state: .fetched, price: 5,  priceAge: DataPolicy.priceTTL + 60)
        add("pending", name: "Pending", state: .pending, price: nil, priceAge: 0)
        try ctx.save()

        let store = CollectionStore.shared(for: container)
        let snapshot = try await store.snapshot(collectionName: "Main", sort: .priceHigh)

        #expect(snapshot.items.map(\.name) == ["Fresh", "Stale", "Pending"])
        #expect(Set(snapshot.pendingIDs) == ["pending"])
        #expect(Set(snapshot.stalePriceIDs) == ["stale"])
    }

    @Test @MainActor func summariesValueFoilsAsFoilAndRankHighlights() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))

        let cheap = CardMeta(scryfallID: "cheap", name: "Cheap", fetchState: .fetched)
        cheap.priceUSD = 1
        let pricey = CardMeta(scryfallID: "pricey", name: "Pricey", fetchState: .fetched)
        pricey.priceUSD = 10; pricey.priceUSDFoil = 40
        ctx.insert(cheap); ctx.insert(pricey)

        let e1 = CollectionEntry(scryfallID: "cheap", collectionName: "Main", quantity: 3); e1.card = cheap
        let e2 = CollectionEntry(scryfallID: "pricey", collectionName: "Main", finish: .foil, quantity: 1); e2.card = pricey
        ctx.insert(e1); ctx.insert(e2)
        try ctx.save()

        let summary = try #require(try await CollectionStore.shared(for: container).summaries().first)
        #expect(summary.totalCopies == 4)
        #expect(summary.uniqueCards == 2)
        #expect(summary.totalValue == 43)           // 3×1 + 1×40 (foil priced as foil)
        #expect(summary.highlights.first?.id == e2.id.uuidString)
    }

    /// One read of the rows serves the overview (with the names the tab
    /// backfills from), every snapshot and the deck screens' owned cards
    /// under the same stamp; decks' hidden collections count as deck copies
    /// and are never offered as collections or as owned cards.
    @Test @MainActor func overviewSnapshotsAndOwnedCardsShareOneRead() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        let meta = CardMeta(scryfallID: "a", name: "Alpha", fetchState: .fetched)
        meta.priceUSD = 2
        ctx.insert(meta)
        // "Legacy" has rows but no MTGCollection yet: the backfill's case.
        for (collection, quantity) in [("Main", 2), ("Legacy", 1), ("deck:123", 1)] {
            let entry = CollectionEntry(scryfallID: "a", collectionName: collection, quantity: quantity)
            entry.card = meta
            ctx.insert(entry)
        }
        try ctx.save()

        let store = CollectionStore.shared(for: container)
        let stamp = StoreStamp(change: 1, hydration: 1)
        let overview = try await store.overview(stamp: stamp)
        #expect(overview.entryCollectionNames == ["Main", "Legacy"])
        #expect(overview.collections.map(\.name) == ["Main"])
        #expect(overview.all.totalCopies == 4 && overview.deckCopies == 1)
        #expect(overview.all.totalValue == 8)

        let main = try await store.snapshot(collectionName: "Main", sort: .name, stamp: stamp)
        #expect(main.items.map(\.quantity) == [2])
        let all = try await store.snapshot(collectionName: CollectionScope.allKey, sort: .name, stamp: stamp)
        #expect(all.items.count == 3)
        let owned = try await store.ownedCards(stamp: stamp)
        #expect(owned.map(\.collectionName).sorted() == ["Legacy", "Main"])
    }
}
