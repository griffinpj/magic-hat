import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// Undo and redo against the real store: rows come back exactly as they
/// were, copies are conserved through deck builds, and a new action after
/// an undo leaves nothing to redo.
@MainActor
@Suite("Undo and redo", .serialized)
struct UndoRedoTests {
    private func row(_ scryfallID: String, in collection: String, _ container: ModelContainer) throws -> CollectionEntry? {
        try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.scryfallID == scryfallID && $0.collectionName == collection }
        )).first
    }

    private func rowCount(in collection: String, _ container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.collectionName == collection }
        )).count
    }

    private func add(_ id: String, _ name: String, to collection: String, quantity: Int = 1,
                     language: String = "en", price: Double? = nil, context: ModelContext) throws {
        try CollectionEditController.add(
            .init(printing: PrintingSelection(item: TestSupport.card(id: id, name: name)),
                  collectionName: collection, quantity: quantity, language: language, purchasePrice: price),
            context: context
        )
    }

    @Test func removalUndoesBackToTheSameRowAndRedoes() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try ctx.save()
        try add("x1", "Xeno", to: "Main", quantity: 2, language: "de", price: 3.5, context: ctx)
        let undo = UndoController(container: container)
        await undo.refresh()
        #expect(undo.canUndo && !undo.canRedo)
        #expect(undo.undoTitle == "Undo Added Cards")

        let entryID = try #require(try row("x1", in: "Main", container)?.id)
        try CollectionEditController.remove(entryID: entryID, context: ctx)
        #expect(try row("x1", in: "Main", container) == nil)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Removed Cards")

        await undo.undo()
        #expect(undo.error == nil)
        let back = try #require(try row("x1", in: "Main", container))
        #expect(back.quantity == 2 && back.language == "de" && back.purchasePrice == 3.5, "the row comes back as it was")
        #expect(undo.canRedo && undo.redoTitle == "Redo Removed Cards")
        #expect(undo.log.actions.first?.state == .undone)

        await undo.undo()
        #expect(try row("x1", in: "Main", container) == nil, "the add undone too")
        #expect(!undo.canUndo && undo.canRedo)

        await undo.redo()
        #expect(try row("x1", in: "Main", container)?.quantity == 2)
        await undo.redo()
        #expect(try row("x1", in: "Main", container) == nil)
        #expect(!undo.canRedo && undo.canUndo)

        // The ledger kept every step: two user actions, four replays.
        let records = try ModelContext(container).fetch(FetchDescriptor<AuditRecord>())
        let kinds = Dictionary(grouping: records, by: \.actionID).values.map { $0[0].action }
        #expect(kinds.filter(\.isUserAction).count == 2)
        #expect(kinds.filter { $0 == .undo }.count == 2 && kinds.filter { $0 == .redo }.count == 2)
        #expect(records.filter { !$0.action.isUserAction }.allSatisfy { $0.undoesActionID != nil })
    }

    @Test func aNewActionForksTheTimelineAndBothBranchesStayReachable() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try ctx.save()
        for i in 0..<10 { try add("c\(i)", "Card \(i)", to: "Main", context: ctx) }
        let undo = UndoController(container: container)
        await undo.refresh()
        let original = undo.log.timeline.applied

        for _ in 0..<5 { await undo.undo() }
        #expect(try rowCount(in: "Main", container) == 5)
        #expect(undo.log.timeline.redoOptions == [original[5]])
        for _ in 0..<5 { await undo.redo() }
        #expect(try rowCount(in: "Main", container) == 10)
        for _ in 0..<3 { await undo.undo() }
        #expect(try rowCount(in: "Main", container) == 7 && undo.canRedo)

        // The fork: a new action while three could be redone.
        try add("c10", "Card 10", to: "Main", context: ctx)
        await undo.refresh()
        let fresh = try #require(undo.log.timeline.head)
        #expect(!undo.canRedo, "the head has no children yet")
        #expect(undo.log.actions.filter { $0.state == .undone }.count == 3, "the old branch is undone, not gone")
        #expect(try rowCount(in: "Main", container) == 8)
        #expect(try row("c10", in: "Main", container) != nil && (try row("c7", in: "Main", container)) == nil)

        // Back to the fork: both ways forward are offered, the recent one first.
        await undo.undo()
        #expect(undo.log.timeline.isFork)
        #expect(undo.log.timeline.redoOptions == [fresh, original[7]])
        #expect(undo.log.redoOptions.count == 2 && undo.log.branchLength(from: original[7]) == 3)

        // Take the original branch to its end.
        await undo.redo(branch: original[7])
        #expect(try rowCount(in: "Main", container) == 8 && (try row("c7", in: "Main", container)) != nil)
        await undo.redo(through: original[9])
        #expect(try rowCount(in: "Main", container) == 10 && !undo.canRedo)
        #expect(try row("c10", in: "Main", container) == nil)
        #expect(undo.log.timeline.applied == original)

        // And across to the other branch in one jump: three back, one forward.
        #expect(undo.log.timeline.jumpPath(to: fresh) == (Array(original[7...].reversed()), [fresh]))
        await undo.jump(to: fresh)
        #expect(try rowCount(in: "Main", container) == 8 && (try row("c10", in: "Main", container)) != nil)
        #expect(undo.log.timeline.head == fresh)

        // All the way back, and all the way forward along the recent branch.
        for _ in 0..<8 { await undo.undo() }
        #expect(try rowCount(in: "Main", container) == 0 && !undo.canUndo)
        for _ in 0..<8 { await undo.redo() }
        #expect(try rowCount(in: "Main", container) == 8 && undo.log.timeline.head == fresh)
        #expect(undo.error == nil)
    }

    @Test func multiStepJumpsThroughAnAction() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try ctx.save()
        for i in 0..<4 { try add("m\(i)", "Card \(i)", to: "Main", context: ctx) }
        let undo = UndoController(container: container)
        await undo.refresh()
        let second = undo.log.timeline.applied[1]
        await undo.undo(through: second)
        #expect(try rowCount(in: "Main", container) == 1 && undo.log.actions.filter { $0.state == .undone }.count == 3)
        let deepest = try #require(undo.log.actions.first { $0.state == .undone })   // newest first: the deepest undone
        await undo.redo(through: deepest.actionID)
        #expect(try rowCount(in: "Main", container) == 4 && !undo.canRedo)
    }

    @Test func aDeckBuildUndoesHomeAndRedoesAndSoDoesDisassembly() async throws {
        let w = try DeckBuilderTests.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let store = DeckStore.shared(for: w.container)
        let before = try DeckBuilderTests.copies(in: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)
        #expect(try DeckBuilderTests.copies(in: w.container)[w.deck.collectionKey] == 3)

        let undo = UndoController(container: w.container)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Built Deck")
        #expect(undo.log.actions.first?.scopes.contains("Deck: Test Deck") == true, "History labels the deck's rows")
        await undo.undo()
        #expect(undo.error == nil)
        #expect(try DeckBuilderTests.copies(in: w.container) == before, "every copy back where it came from")
        var snap = try #require(try await store.snapshot(deckID: w.deck.id))
        #expect(snap.builtCopies == 0)
        #expect(snap.allItems.first { $0.card.name == "Alpha" }?.status == .available)

        await undo.redo()
        snap = try #require(try await store.snapshot(deckID: w.deck.id))
        #expect(snap.builtCopies == 3)
        let deckRows = try ModelContext(w.container).fetch(FetchDescriptor<CollectionEntry>()).filter { $0.collectionName == w.deck.collectionKey }
        #expect(deckRows.allSatisfy { $0.sourceCollectionName == "Main" }, "a rebuilt deck row still knows its home")

        _ = try await builder.disassemble(deckID: w.deck.id)
        #expect(try DeckBuilderTests.copies(in: w.container)[w.deck.collectionKey] == nil)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Disassembled Deck")
        await undo.undo()
        #expect(try DeckBuilderTests.copies(in: w.container)[w.deck.collectionKey] == 3, "disassembly undone: built again")
        await undo.redo()
        #expect(try DeckBuilderTests.copies(in: w.container) == before)
        #expect(undo.error == nil)
    }

    @Test func anImportUndoesToEmptyAndRedoesIntact() async throws {
        let container = try TestSupport.makeContainer()
        let rows = [
            TestSupport.row(binder: "B", id: "i1", quantity: 2),
            TestSupport.row(binder: "B", id: "i2", finish: "foil", quantity: 1, price: 9.25),
        ]
        _ = try await ImportController.apply(rows: rows, selectedBinders: ["B"], collectionName: "Imported",
                                             mode: .add, container: container) { _ in }
        #expect(try rowCount(in: "Imported", container) == 2)
        let undo = UndoController(container: container)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Import")

        await undo.undo()
        #expect(try rowCount(in: "Imported", container) == 0)
        let collections = try ModelContext(container).fetch(FetchDescriptor<MTGCollection>()).map(\.name)
        #expect(collections.contains("Imported"), "the collection stays; only its rows were the import")

        await undo.redo()
        #expect(try rowCount(in: "Imported", container) == 2)
        let foil = try #require(try row("i2", in: "Imported", container))
        #expect(foil.finish == .foil && foil.purchasePrice == 9.25 && foil.quantity == 1)
        #expect(undo.error == nil)
    }

    @Test func deletingACollectionUndoesToTheCollectionAndItsRows() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Trade"))
        try ctx.save()
        try add("t1", "Trade One", to: "Trade", quantity: 3, context: ctx)
        try add("t2", "Trade Two", to: "Trade", context: ctx)
        _ = try await CollectionEditController.delete(collectionName: "Trade", context: ctx)
        #expect(try rowCount(in: "Trade", container) == 0)
        #expect(!(try ModelContext(container).fetch(FetchDescriptor<MTGCollection>()).map(\.name)).contains("Trade"))

        let undo = UndoController(container: container)
        await undo.refresh()
        await undo.undo()
        #expect(undo.error == nil)
        #expect(try rowCount(in: "Trade", container) == 2)
        #expect(try row("t1", in: "Trade", container)?.quantity == 3)
        #expect((try ModelContext(container).fetch(FetchDescriptor<MTGCollection>()).map(\.name)).contains("Trade"))
    }

    @Test func aBuildWhoseDeckIsGoneIsRefusedWholesale() async throws {
        let w = try DeckBuilderTests.makeWorld()
        let builder = DeckBuilder.shared(for: w.container)
        let plan = try await builder.plan(deckID: w.deck.id, sourceCollections: nil, includeSideboard: false)
        _ = try await builder.build(plan)
        let built = try DeckBuilderTests.copies(in: w.container)
        w.container.mainContext.delete(w.deck)
        try w.container.mainContext.save()

        let undo = UndoController(container: w.container)
        await undo.refresh()
        await undo.undo()
        #expect(undo.error?.contains("no longer exists") == true)
        #expect(try DeckBuilderTests.copies(in: w.container) == built, "nothing moved")
        #expect(undo.canUndo, "the action is still there to try again")
    }

    @Test func recordsFromBeforeDeckKeysAreNotUndoable() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(AuditRecord(actionID: UUID(), action: .deckBuild, scryfallID: "a1", cardName: "Alpha",
                               collectionName: "Deck: Old", finish: .normal, condition: "near_mint",
                               quantityDelta: 1, collectionEntryID: nil))
        try ctx.save()
        let undo = UndoController(container: container)
        await undo.refresh()
        #expect(undo.log.actions.first?.scopes == ["Deck: Old"])
        await undo.undo()
        #expect(undo.error?.contains("before undo existed") == true)
    }
}
