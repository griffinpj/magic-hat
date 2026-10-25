import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// Building moves copies out of collections into the deck's hidden
/// collection and disassembling moves them back — never duplicating, always
/// in paired audit records under one action.
@MainActor
@Suite("DeckBuilder")
struct DeckBuilderTests {
    struct World {
        let container: ModelContainer
        let deck: Deck
    }

    /// Collection "Main": A ×2 (normal) + A ×1 (foil, different printing), C ×1.
    /// Deck: commander C, main A ×2, B ×1 (not owned).
    static func makeWorld() throws -> World {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        ctx.insert(MTGCollection(name: "Trade Binder"))

        func meta(_ id: String, _ name: String, oracle: String) -> CardMeta {
            let m = CardMeta(scryfallID: id, name: name, setCode: "tst", setName: "Test", collectorNumber: id, rarity: "rare", fetchState: .fetched)
            m.oracleID = oracle
            m.colorsRaw = "R"; m.colorIdentityRaw = "R"
            m.typeLine = "Creature — Dwarf"; m.manaCost = "{1}{R}"
            m.priceUSD = 2
            ctx.insert(m)
            return m
        }
        let a1 = meta("a1", "Alpha", oracle: "oracle-a")
        let a2 = meta("a2", "Alpha", oracle: "oracle-a")   // another printing
        _ = meta("b1", "Beta", oracle: "oracle-b")
        let c1 = meta("c1", "Captain", oracle: "oracle-c")

        func entry(_ meta: CardMeta, collection: String, qty: Int, finish: CardFinish = .normal) {
            let e = CollectionEntry(scryfallID: meta.scryfallID, collectionName: collection, name: meta.name,
                                    setCode: "tst", setName: "Test", collectorNumber: meta.collectorNumber,
                                    rarity: "rare", finish: finish, quantity: qty, purchasePrice: 1.5)
            e.card = meta
            ctx.insert(e)
        }
        entry(a1, collection: "Main", qty: 2)
        entry(a2, collection: "Trade Binder", qty: 1, finish: .foil)
        entry(c1, collection: "Main", qty: 1)

        let deck = try DeckEditController.createDeck(name: "Test Deck", format: .commander,
                                                     commander: nil, context: ctx)
        for (id, oracle, name, board, qty) in [("c1", "oracle-c", "Captain", DeckBoard.commander, 1),
                                                ("a1", "oracle-a", "Alpha", .main, 2),
                                                ("b1", "oracle-b", "Beta", .main, 1)] {
            let card = DeckCard(scryfallID: id, oracleID: oracle, name: name, board: board, quantity: qty)
            card.deck = deck
            ctx.insert(card)
        }
        try ctx.save()
        return World(container: container, deck: deck)
    }

    static func copies(in container: ModelContainer) throws -> [String: Int] {
        let entries = try container.mainContext.fetch(FetchDescriptor<CollectionEntry>())
        var out: [String: Int] = [:]
        for e in entries { out[e.collectionName, default: 0] += e.quantity }
        return out
    }

    @Test func planTakesExactPrintingsAndNonFoilsFirstAndReportsMissing() async throws {
        let w = try Self.makeWorld()
        let plan = try await DeckBuilder.shared(for: w.container).plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        #expect(plan.readyCopies == 3, "commander + two Alphas")
        #expect(plan.missingCopies == 1, "Beta is not owned")
        let alpha = try #require(plan.entries.first { $0.name == "Alpha" })
        #expect(alpha.takes.count == 1 && alpha.takes[0].quantity == 2, "both from the exact non-foil stack")
        #expect(alpha.takes[0].fromCollection == "Main")
        #expect(plan.missingEntries.map(\.name) == ["Beta"])
        _ = w
    }

    @Test func buildMovesCopiesWithoutDuplicatingAndAuditsInPairs() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let before = try Self.copies(in: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        let result = try await builder.build(plan)
        #expect(result.movedCopies == 3)

        let after = try Self.copies(in: w.container)
        #expect(after[w.deck.collectionKey] == 3)
        #expect(after["Main"] == 0 || after["Main"] == nil, "Main gave up both Alphas and the Captain")
        #expect(after["Trade Binder"] == 1, "the foil stayed home")
        #expect(before.values.reduce(0, +) == after.values.reduce(0, +), "copies are conserved")

        let deckKey = w.deck.collectionKey
        let deckEntries = try w.container.mainContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == deckKey }))
        #expect(deckEntries.allSatisfy { $0.sourceCollectionName == "Main" })
        #expect(deckEntries.allSatisfy { $0.card != nil }, "the meta link travels with the copy")

        let audits = try w.container.mainContext.fetch(FetchDescriptor<AuditRecord>())
        let builds = audits.filter { $0.action == .deckBuild }
        #expect(Set(builds.map(\.actionID)).count == 1, "one action")
        #expect(builds.reduce(0) { $0 + $1.quantityDelta } == 0, "every −n has its +n")
        #expect(builds.filter { $0.quantityDelta > 0 }.allSatisfy { $0.collectionName == w.deck.collectionKey },
                "deck rows are recorded under the deck's key, which undo needs")

        // The snapshot sees it.
        let snap = try #require(try await DeckStore.shared(for: w.container).snapshot(deckID: w.deck.id))
        #expect(snap.builtCopies == 3)
        #expect(snap.commanders.first?.status == .built)
        #expect(snap.sections.flatMap(\.items).first { $0.card.name == "Beta" }?.status == .missing)
        #expect(snap.stats.missingCopies == 1)

        // Building again finds nothing left to move.
        let again = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        #expect(again.readyCopies == 0 && again.missingCopies == 1)
    }

    @Test func disassembleReturnsEveryCopyHomeAndMerges() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)
        let result = try await builder.disassemble(deckID: w.deck.id)
        #expect(result.returnedCopies == 3)

        let after = try Self.copies(in: w.container)
        #expect(after[w.deck.collectionKey] == nil)
        #expect(after["Main"] == 3)
        #expect(after["Trade Binder"] == 1)
        let main = try w.container.mainContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == "Main" }))
        #expect(main.count == 2, "Alpha ×2 and Captain ×1 merged back into two rows, not four")

        let audits = try w.container.mainContext.fetch(FetchDescriptor<AuditRecord>()).filter { $0.action == .deckDisassemble }
        #expect(audits.reduce(0) { $0 + $1.quantityDelta } == 0)
        #expect(Set(audits.map(\.actionID)).count == 1)
    }

    @Test func disassembleIntoOneCollectionSendsEveryRowThere() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)
        let result = try await builder.disassemble(deckID: w.deck.id, destination: .collection("Trade Binder"))
        #expect(result.returnedCopies == 3 && result.removedCopies == 0)

        let after = try Self.copies(in: w.container)
        #expect(after[w.deck.collectionKey] == nil)
        #expect(after["Main"] == nil, "nothing went back to where it came from")
        #expect(after["Trade Binder"] == 4, "the foil Alpha already there, plus the three from the deck")

        // A collection that doesn't exist yet is made; a list is refused.
        _ = try await builder.build(try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false))
        _ = try await builder.disassemble(deckID: w.deck.id, destination: .collection("Shoebox"))
        let names = Set(try w.container.mainContext.fetch(FetchDescriptor<MTGCollection>()).map(\.name))
        #expect(names.contains("Shoebox"))
        #expect(try Self.copies(in: w.container)["Shoebox"] == 3)

        w.container.mainContext.insert(MTGCollection(name: "Wants", kind: .list))
        try w.container.mainContext.save()
        _ = try await builder.build(try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false))
        await #expect(throws: DeckBuilder.BuildError.self) {
            try await builder.disassemble(deckID: w.deck.id, destination: .collection("Wants"))
        }
        #expect(try Self.copies(in: w.container)[w.deck.collectionKey] == 3, "refused before anything moved")
    }

    @Test func disassembleDiscardRemovesTheCopiesAsARemoval() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)
        let before = try Self.copies(in: w.container)
        #expect(before[w.deck.collectionKey] == 3)

        let result = try await builder.disassemble(deckID: w.deck.id, destination: .discard)
        #expect(result.returnedCopies == 0 && result.removedCopies == 3)
        let after = try Self.copies(in: w.container)
        #expect(after[w.deck.collectionKey] == nil)
        #expect(after["Main"] == nil && after["Trade Binder"] == 1, "nothing came back")

        // One History action, a removal of three copies from the deck, so
        // Undo can put them back into the deck.
        let audits = try w.container.mainContext.fetch(FetchDescriptor<AuditRecord>())
            .filter { $0.actionID == result.actionID }
        #expect(audits.allSatisfy { $0.action == .manualRemove && $0.collectionName == w.deck.collectionKey })
        #expect(audits.reduce(0) { $0 + $1.quantityDelta } == -3)

        // An empty deck disassembles to nothing, whatever the destination.
        let again = try await builder.disassemble(deckID: w.deck.id, destination: .discard)
        #expect(again.removedCopies == 0)
    }

    @Test func deletingABuiltDeckIsRefusedUntilItIsTakenApart() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        _ = try await builder.build(try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false))
        #expect(throws: DeckEditController.EditError.self) {
            try DeckEditController.delete(deckID: w.deck.id, context: w.container.mainContext)
        }
        #expect(try w.container.mainContext.fetch(FetchDescriptor<Deck>()).count == 1, "still there")
        _ = try await builder.disassemble(deckID: w.deck.id)
        try DeckEditController.delete(deckID: w.deck.id, context: w.container.mainContext)
        #expect(try w.container.mainContext.fetch(FetchDescriptor<Deck>()).isEmpty)
    }

    @Test func rowsOfADeletedDeckAreLabelledNotKeyed() async throws {
        let w = try Self.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        _ = try await builder.build(try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false))
        // The deck row gone with its cards left behind (what an older
        // build did when it deleted on a stale built count).
        let ctx = w.container.mainContext
        let deck = try #require(try ctx.fetch(FetchDescriptor<Deck>()).first)
        try DeckEditController.remove(deck, in: ctx)
        try ctx.save()
        let store = CollectionStore(modelContainer: w.container)
        let rows = try await store.ownedItems(scryfallIDs: ["a1", "c1"])
        let orphans = rows.filter { Deck.isDeckCollection($0.collectionName) }
        #expect(!orphans.isEmpty)
        #expect(orphans.allSatisfy { $0.displayCollection == "Deleted Deck" }, "never deck:<uuid>")
    }

    @Test func snapshotShowsAvailabilityBeforeBuilding() async throws {
        let w = try Self.makeWorld()
        let snap = try #require(try await DeckStore.shared(for: w.container).snapshot(deckID: w.deck.id))
        #expect(snap.identity == [.red])
        #expect(snap.mainCopies == 4)
        let alpha = try #require(snap.allItems.first { $0.card.name == "Alpha" })
        #expect(alpha.status == .available && alpha.availableQuantity == 2)
        #expect(snap.stats.availableCopies == 3 && snap.stats.missingCopies == 1)
        #expect(snap.stats.issues.contains { $0.kind == .tooFew })
        #expect(snap.subtitle == "Commander · 4/100")
    }

    @Test func listEditsMergeByCardAndZeroRemoves() throws {
        let w = try Self.makeWorld()
        let ctx = w.container.mainContext
        // Another printing of the same card (same oracle) already on the
        // mainboard → merged into that row, not a new one.
        let p = PrintingSelection(item: try CardSearchQueryMatchingTests.item(
            ["id": "a2", "name": "Alpha", "oracle_id": "oracle-a", "set": "tst", "collector_number": "a2"]
        ))
        let id = try DeckEditController.add(p, to: w.deck.id, board: .main, context: ctx)
        let alpha = try #require(w.deck.cards.first { $0.name == "Alpha" && $0.board == .main })
        #expect(id == alpha.id && alpha.quantity == 3)
        try DeckEditController.setQuantity(deckCardID: alpha.id, 0, context: ctx)
        #expect(!w.deck.cards.contains { $0.name == "Alpha" })
        try DeckEditController.setLocked(deckID: w.deck.id, true, context: ctx)
        #expect(w.deck.isLocked)
    }
}
