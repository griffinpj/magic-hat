import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// Lists hold cards that are wanted, not owned: browsable like any
/// collection, invisible to everything that counts what you have.
@MainActor
@Suite("Lists", .serialized)
struct ListTests {
    private func world() throws -> ModelContainer {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        ctx.insert(MTGCollection(name: "Wishlist", kind: .list))
        for (id, name, collection, qty) in [("a", "Alpha", "Main", 2), ("b", "Beta", "Wishlist", 3), ("a", "Alpha", "Wishlist", 1)] {
            let meta = try ctx.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.scryfallID == id })).first
                ?? { let m = CardMeta(scryfallID: id, name: name, fetchState: .fetched); m.oracleID = "o-\(id)"; m.priceUSD = 1; ctx.insert(m); return m }()
            let entry = CollectionEntry(scryfallID: id, collectionName: collection, name: name, quantity: qty)
            entry.card = meta
            ctx.insert(entry)
        }
        try ctx.save()
        return container
    }

    @Test func listRowsAreBrowsableButNeverOwned() async throws {
        let container = try world()
        let store = CollectionStore(modelContainer: container)

        let list = try await store.snapshot(collectionName: "Wishlist", sort: .name)
        #expect(list.items.map(\.name) == ["Alpha", "Beta"])
        #expect(list.items.allSatisfy { $0.inList && $0.isEntry }, "editable rows, marked as a list's")
        #expect(list.items.map(\.inCollection) == [true, false], "Alpha is owned in Main; Beta is only wanted")
        let stamp = StoreStamp(change: 1, hydration: 1)
        _ = try await store.overview(stamp: stamp)
        let cached = try await store.snapshot(collectionName: "Wishlist", sort: .name, stamp: stamp)
        #expect(cached.items.map(\.inCollection) == [true, false], "the same from the shared rows")

        let all = try await store.snapshot(collectionName: CollectionScope.allKey, sort: .name)
        #expect(all.items.map(\.name) == ["Alpha"], "All Collection is what is owned")

        let overview = try await store.overview()
        #expect(overview.all.totalCopies == 2)
        #expect(overview.collections.first { $0.name == "Wishlist" }?.isList == true)
        #expect(overview.collections.first { $0.name == "Wishlist" }?.totalCopies == 4)

        #expect(try await store.ownedScryfallIDs() == ["a"])
        #expect(try await store.ownedIndex().copiesByKey == ["o-a": 2])
        #expect(try await store.collectionNames(kind: .collection) == ["Main"])
    }

    /// The same cards put on a list and then added to a collection are
    /// two rows that say where: the place leads, and the list's is marked.
    @Test func historyTellsAListAddFromACollectionAdd() async throws {
        let container = try world()
        let ctx = container.mainContext
        let card = TestSupport.card(id: "z", name: "Zeta")
        try CollectionEditController.add(.init(printing: PrintingSelection(item: card), collectionName: "Wishlist", quantity: 2), context: ctx)
        try CollectionEditController.add(.init(printing: PrintingSelection(item: card), collectionName: "Main", quantity: 2), context: ctx)
        let log = try await CollectionStore(modelContainer: container).history()
        let onList = try #require(log.actions.first { $0.scopes == ["Wishlist"] })
        let owned = try #require(log.actions.first { $0.scopes == ["Main"] })
        #expect(onList.title == owned.title, "the same title: the detail has to tell them apart")
        #expect(onList.isListOnly && onList.detail == "Wishlist (list)")
        #expect(!owned.isListOnly && owned.detail == "Main")
    }

    @Test func aDeckIsNeverBuiltFromAList() async throws {
        let container = try world()
        let ctx = container.mainContext
        let deck = try DeckEditController.createDeck(name: "D", format: .other, commander: nil, context: ctx)
        let card = DeckCard(scryfallID: "b", oracleID: "o-b", name: "Beta", board: .main, quantity: 1)
        card.deck = deck
        ctx.insert(card)
        try ctx.save()
        let plan = try await DeckBuilder(modelContainer: container).plan(deckID: deck.id, sourceCollections: nil, includeSideboard: false)
        #expect(plan.readyCopies == 0 && plan.missingCopies == 1, "Beta is only on the wishlist")
    }

    @Test func undoingADeletedListBringsBackAList() async throws {
        let container = try world()
        let ctx = container.mainContext
        try await CollectionEditController.delete(collectionName: "Wishlist", in: ctx, progress: { _ in })
        #expect(try ctx.fetch(FetchDescriptor<MTGCollection>()).map(\.name) == ["Main"])

        let undo = UndoController(container: container)
        await undo.refresh()
        await undo.undo()
        #expect(undo.error == nil)
        let restored = try ModelContext(container).fetch(FetchDescriptor<MTGCollection>(predicate: #Predicate { $0.name == "Wishlist" }))
        #expect(restored.first?.kind == .list)
    }
}

@MainActor
@Suite("Import into a list", .serialized)
struct ListImportTests {
    @Test func textLinesLandAsOneAction() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Wants", kind: .list))
        for (id, name, set, number) in [("s1", "Sol Ring", "c21", "263"), ("b1", "Lightning Bolt", "m11", "146")] {
            let meta = CardMeta(scryfallID: id, name: name, setCode: set, setName: set.uppercased(), collectorNumber: number,
                                rarity: "rare", fetchState: .fetched)
            meta.oracleID = "o-\(id)"
            meta.priceUSD = 1
            ctx.insert(meta)
        }
        try ctx.save()
        let file = CardListReader.read("2 Sol Ring (C21) 263\n1 Lightning Bolt *F*\n")
        let result = try await CollectionImportController.importCards(file.cards, into: "Wants", container: container, remote: false)
        #expect(result.copies == 3 && result.unresolved.isEmpty)
        let rows = try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>())
        #expect(rows.count == 2 && rows.allSatisfy { $0.collectionName == "Wants" })
        #expect(rows.first { $0.scryfallID == "b1" }?.finish == .foil)
        let actions = Set(try ModelContext(container).fetch(FetchDescriptor<AuditRecord>()).map(\.actionID))
        #expect(actions.count == 1, "one History action")
    }
}
