import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("CollectionEditController", .serialized)
@MainActor
struct CollectionEditControllerTests {
    private func entries(_ ctx: ModelContext) throws -> [CollectionEntry] {
        try ctx.fetch(FetchDescriptor<CollectionEntry>())
    }
    private func audits(_ ctx: ModelContext) throws -> [AuditRecord] {
        try ctx.fetch(FetchDescriptor<AuditRecord>())
    }
    private func printing(_ id: String = "p1", name: String = "Doubling Season", price: Double? = 36.40) -> PrintingSelection {
        PrintingSelection(item: TestSupport.card(id: id, name: name, set: "fdn", number: "216", rarity: "mythic", price: price))
    }

    @Test func addCreatesCollectionEntryMetaAndAudit() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        let actionID = try CollectionEditController.add(
            .init(printing: printing(), collectionName: "Library", quantity: 2, purchasePrice: 30),
            context: ctx
        )
        let rows = try entries(ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.quantity == 2)
        #expect(rows.first?.collectionName == "Library")
        #expect(rows.first?.purchasePrice == 30)
        #expect(rows.first?.card?.scryfallID == "p1", "linked to a CardMeta placeholder")
        #expect(rows.first?.card?.name == "Doubling Season")
        #expect(try ctx.fetch(FetchDescriptor<MTGCollection>()).map(\.name) == ["Library"])
        let a = try audits(ctx)
        #expect(a.count == 1)
        #expect(a.first?.actionID == actionID)
        #expect(a.first?.quantityDelta == 2)
        #expect(a.first?.action == .manualAdd)
    }

    @Test func addingTheSameIdentityMergesQuantities() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 1), context: ctx)
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 3), context: ctx)
        let rows = try entries(ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.quantity == 4)
        #expect(try audits(ctx).map(\.quantityDelta).sorted() == [1, 3])
    }

    @Test func differentFinishOrCollectionIsASeparateRow() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", finish: .normal), context: ctx)
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", finish: .foil), context: ctx)
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Trade", finish: .normal), context: ctx)
        #expect(try entries(ctx).count == 3)
        #expect(try ctx.fetch(FetchDescriptor<CardMeta>()).count == 1, "one shared CardMeta")
    }

    @Test func addRejectsBadInput() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        #expect(throws: CollectionEditError.self) {
            try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 0), context: ctx)
        }
        #expect(throws: CollectionEditError.self) {
            try CollectionEditController.add(.init(printing: printing(), collectionName: "   "), context: ctx)
        }
        #expect(try entries(ctx).isEmpty)
    }

    @Test func updateQuantityRecordsTheDelta() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 4), context: ctx)
        let id = try #require(try entries(ctx).first?.id)
        try CollectionEditController.update(
            entryID: id,
            edits: .init(quantity: 1, finish: .normal, condition: CardCondition.nearMint.rawValue, language: "en", purchasePrice: 12),
            context: ctx
        )
        let row = try #require(try entries(ctx).first)
        #expect(row.quantity == 1)
        #expect(row.purchasePrice == 12)
        #expect(try audits(ctx).map(\.quantityDelta).sorted() == [-3, 4])
    }

    @Test func updateThatChangesIdentityMergesIntoTheMatchingRow() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 2, finish: .normal), context: ctx)
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 1, finish: .foil), context: ctx)
        let normal = try #require(try entries(ctx).first { $0.finish == .normal })
        // Turn the normal row into foil: it should fold into the foil row.
        try CollectionEditController.update(
            entryID: normal.id,
            edits: .init(quantity: 2, finish: .foil, condition: CardCondition.nearMint.rawValue, language: "en", purchasePrice: nil),
            context: ctx
        )
        let rows = try entries(ctx)
        #expect(rows.count == 1)
        #expect(rows.first?.finish == .foil)
        #expect(rows.first?.quantity == 3)
        // -2 from the old identity, +2 to the new one, plus the two adds.
        #expect(try audits(ctx).map(\.quantityDelta).sorted() == [-2, 1, 2, 2])
    }

    @Test func updateThatChangesIdentityWithoutACollisionKeepsTheRow() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 2), context: ctx)
        let id = try #require(try entries(ctx).first?.id)
        try CollectionEditController.update(
            entryID: id,
            edits: .init(quantity: 2, finish: .normal, condition: CardCondition.lightlyPlayed.rawValue, language: "ja", purchasePrice: nil),
            context: ctx
        )
        let row = try #require(try entries(ctx).first)
        #expect(row.id == id)
        #expect(row.condition == "lightly_played")
        #expect(row.language == "ja")
        #expect(try audits(ctx).count == 3, "add, then remove-old-identity + add-new-identity")
    }

    @Test func removeDeletesAndRecords() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        try CollectionEditController.add(.init(printing: printing(), collectionName: "Library", quantity: 3), context: ctx)
        let id = try #require(try entries(ctx).first?.id)
        try CollectionEditController.remove(entryID: id, context: ctx)
        #expect(try entries(ctx).isEmpty)
        #expect(try audits(ctx).map(\.quantityDelta).sorted() == [-3, 3])
        #expect(throws: CollectionEditError.self) {
            try CollectionEditController.remove(entryID: id, context: ctx)
        }
    }

    @Test func createCollectionRejectsBlankAndDuplicates() async throws {
        let container = try TestSupport.makeContainer(); let ctx = container.mainContext
        #expect(try CollectionEditController.createCollection(named: "  Trade Binder ", context: ctx))
        #expect(try CollectionEditController.createCollection(named: "trade binder", context: ctx) == false)
        #expect(try CollectionEditController.createCollection(named: "   ", context: ctx) == false)
        #expect(try ctx.fetch(FetchDescriptor<MTGCollection>()).map(\.name) == ["Trade Binder"])
    }

    @Test func storeFindsOwnedCopiesAcrossPrintingsAndCollections() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        // Two printings of the same card, tied together by oracle id.
        let a = CardMeta(scryfallID: "print-a", name: "Card", fetchState: .fetched); a.oracleID = "oracle-1"
        let b = CardMeta(scryfallID: "print-b", name: "Card", fetchState: .fetched); b.oracleID = "oracle-1"
        let other = CardMeta(scryfallID: "print-z", name: "Other", fetchState: .fetched); other.oracleID = "oracle-2"
        for m in [a, b, other] { ctx.insert(m) }
        try ctx.save()
        try CollectionEditController.add(.init(printing: printing("print-a", name: "Card"), collectionName: "Library"), context: ctx)
        try CollectionEditController.add(.init(printing: printing("print-b", name: "Card"), collectionName: "Trade"), context: ctx)
        try CollectionEditController.add(.init(printing: printing("print-z", name: "Other"), collectionName: "Library"), context: ctx)

        let store = CollectionStore.shared(for: container)
        let ids = try await store.printingIDs(oracleID: "oracle-1")
        #expect(Set(ids) == ["print-a", "print-b"])
        let owned = try await store.ownedItems(scryfallIDs: ids)
        #expect(owned.count == 2)
        #expect(Set(owned.map(\.collectionName)) == ["Library", "Trade"])
        #expect(owned.allSatisfy { $0.owned })
    }
}

@Suite("PrintingSelection")
struct PrintingSelectionTests {
    @Test func marketPriceFollowsFinishWithFoilFallback() {
        var item = TestSupport.card(id: "x", name: "X", price: 10)
        var sel = PrintingSelection(item: item)
        #expect(sel.marketPrice(for: .normal) == 10)
        #expect(sel.marketPrice(for: .foil) == 10, "no foil price → falls back to normal")
        item = TestSupport.card(id: "y", name: "Y", price: nil)
        sel = PrintingSelection(item: item)
        #expect(sel.marketPrice(for: .normal) == nil)
    }

    @Test func conditionLabelsTolerateUnknownValues() {
        #expect(CardCondition.label(for: "near_mint") == "Near Mint")
        #expect(CardCondition.shortLabel(for: "lightly_played") == "LP")
        #expect(CardCondition.label(for: "weird_value") == "Weird Value")
        #expect(CardLanguage.name("zhs") == "Chinese (Simplified)")
    }
}
