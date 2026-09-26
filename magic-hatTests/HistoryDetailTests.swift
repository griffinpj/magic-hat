import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// History rows are named for their cards, and a row's detail lists what
/// changed: merged per printing, grouped by collection, a deck build as
/// moves, the largest first, capped and searchable when long.
@MainActor
@Suite("History detail", .serialized)
struct HistoryDetailTests {
    private func add(_ id: String, _ name: String, to collection: String, quantity: Int = 1, context: ModelContext) throws {
        try CollectionEditController.add(
            .init(printing: PrintingSelection(item: TestSupport.card(id: id, name: name)),
                  collectionName: collection, quantity: quantity),
            context: context
        )
    }

    @Test func rowsAreNamedForTheirCards() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try ctx.save()
        try add("bolt", "Lightning Bolt", to: "Main", quantity: 3, context: ctx)
        let store = CollectionStore(modelContainer: container)

        var log = try await store.history()
        let single = try #require(log.actions.first)
        #expect(single.title == "Added Lightning Bolt")
        #expect(single.detail == "Main")
        #expect(single.cardCount == 1 && single.added == 3)

        // Two adds under one action: the names line names them.
        let actionID = UUID()
        for (id, name, qty) in [("ring", "Sol Ring", 4), ("counter", "Counterspell", 1), ("bolt", "Lightning Bolt", 2)] {
            ctx.insert(AuditRecord(actionID: actionID, action: .manualAdd, scryfallID: id, cardName: name,
                                   collectionName: "Main", finish: .normal, condition: "near_mint",
                                   quantityDelta: qty, collectionEntryID: nil))
        }
        try ctx.save()
        log = try await store.history()
        let several = try #require(log.action(actionID))
        #expect(several.title == "Added 3 Cards")
        #expect(several.detail == "Sol Ring, Lightning Bolt and 1 more · Main", "largest changes first")
        #expect(several.cardNames == ["Sol Ring", "Lightning Bolt", "Counterspell"])
    }

    @Test func aDetailMergesPrintingsAndGroupsByCollection() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        ctx.insert(MTGCollection(name: "Trade"))
        try ctx.save()
        let actionID = UUID()
        func record(_ id: String, _ name: String, in collection: String, delta: Int, finish: CardFinish = .normal) {
            ctx.insert(AuditRecord(actionID: actionID, action: .manualAdd, scryfallID: id, cardName: name,
                                   collectionName: collection, finish: finish, condition: "near_mint",
                                   quantityDelta: delta, collectionEntryID: nil))
        }
        record("a", "Alpha", in: "Main", delta: 1)
        record("a", "Alpha", in: "Main", delta: 2)          // the same printing twice: one row, +3
        record("a", "Alpha", in: "Main", delta: 1, finish: .foil)   // a different finish: its own row
        record("b", "Beta", in: "Main", delta: -1)
        record("c", "Gamma", in: "Trade", delta: 6)
        try ctx.save()

        let store = CollectionStore(modelContainer: container)
        let detail = try await store.historyDetail(actionID: actionID)
        #expect(detail.groups.map(\.title) == ["Trade", "Main"], "the group that moved most first")
        let main = try #require(detail.groups.last)
        #expect(main.kind == .scope && main.added == 4 && main.removed == 1 && main.total == 3)
        #expect(main.changes.count == 3)
        #expect(main.changes.map { ($0.name, $0.delta) }.map { "\($0.0):\($0.1)" } == ["Alpha:3", "Alpha:1", "Beta:-1"])
        #expect(main.changes[1].finish == .foil && main.changes[1].printingLine.contains("Foil"))
        #expect(detail.changeCount == 4 && detail.groups.first?.added == 6)

        // Capped and filtered.
        let capped = detail.capped(to: 1)
        #expect(capped.groups.map(\.changes.count) == [1, 1] && capped.groups.last?.hidden == 2)
        let filtered = detail.filtered("alp")
        #expect(filtered.groups.count == 1 && filtered.groups[0].changes.count == 2 && filtered.groups[0].added == 4)
        #expect(detail.filtered("nothing").groups.isEmpty)
        #expect(detail.filtered("  ") == detail)
    }

    @Test func aDeckBuildReadsAsMoves() async throws {
        let w = try DeckBuilderTests.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)

        let store = CollectionStore(modelContainer: w.container)
        let log = try await store.history()
        let build = try #require(log.actions.first)
        #expect(build.title == "Built Test Deck")
        #expect(build.detail == "Alpha, Captain · from Main")
        #expect(build.deckName == "Test Deck" && build.cardCount == 2)

        let detail = try await store.historyDetail(actionID: build.actionID)
        let move = try #require(detail.groups.first)
        #expect(detail.groups.count == 1, "each card once, not a −n and a +n")
        #expect(move.kind == .move && move.title == "Main" && move.destination == "Test Deck")
        #expect(move.added == 3 && move.total == 2)
        #expect(move.changes.map { "\($0.name)×\($0.delta)" } == ["Alpha×2", "Captain×1"])
        #expect(move.changes.allSatisfy { $0.setCode == "tst" && $0.rarity == "rare" }, "the printing from the snapshot")

        _ = try await builder.disassemble(deckID: w.deck.id)
        let back = try #require(try await store.history().actions.first)
        #expect(back.title == "Disassembled Test Deck" && back.detail == "Alpha, Captain · to Main")
        let backDetail = try await store.historyDetail(actionID: back.actionID)
        #expect(backDetail.groups.first?.title == "Test Deck" && backDetail.groups.first?.destination == "Main")
    }

    @Test func anImportIsNamedByItsSize() async throws {
        let container = try TestSupport.makeContainer()
        let rows = (0..<45).map { TestSupport.row(binder: "B", id: "i\($0)", quantity: 1) }
        _ = try await ImportController.apply(rows: rows, selectedBinders: ["B"], collectionName: "Imported",
                                             mode: .add, container: container) { _ in }
        let store = CollectionStore(modelContainer: container)
        let action = try #require(try await store.history().actions.first)
        #expect(action.title == "Imported 45 Cards")
        #expect(action.detail == "Forest and 44 more · Imported", "one name for the fixture's forests, the count of printings")
        let detail = try await store.historyDetail(actionID: action.actionID)
        #expect(detail.changeCount == 45)
        let shown = detail.capped()
        #expect(shown.groups[0].changes.count == HistoryDetail.visibleLimit && shown.groups[0].hidden == 5)
    }
}
