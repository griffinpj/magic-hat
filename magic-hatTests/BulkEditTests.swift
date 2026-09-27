import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// A selection moved or removed at once: one action, copies conserved,
/// merged by merge key at the destination, and undone as a whole.
@MainActor
@Suite("Bulk edits", .serialized)
struct BulkEditTests {
    private func world() throws -> (ModelContainer, [UUID]) {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        ctx.insert(MTGCollection(name: "Trade"))
        ctx.insert(MTGCollection(name: "Wants", kind: .list))
        var ids: [UUID] = []
        for (id, collection, qty) in [("a", "Main", 2), ("b", "Main", 1), ("a", "Trade", 3)] {
            let entry = CollectionEntry(scryfallID: id, collectionName: collection, name: id.uppercased(), quantity: qty)
            ctx.insert(entry)
            if collection == "Main" { ids.append(entry.id) }
        }
        let deckRow = CollectionEntry(scryfallID: "d", collectionName: "deck:\(UUID().uuidString)", name: "D", quantity: 1)
        ctx.insert(deckRow)
        ids.append(deckRow.id)
        try ctx.save()
        return (container, ids)
    }

    private func copies(_ container: ModelContainer) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for e in try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>()) { out["\(e.collectionName)|\(e.scryfallID)", default: 0] += e.quantity }
        return out.filter { !$0.key.hasPrefix("deck:") }
    }

    @Test func moveMergesAtTheDestinationAndUndoes() async throws {
        let (container, ids) = try world()
        let summary = try CollectionEditController.move(entryIDs: ids, to: "Trade", in: ModelContext(container))
        #expect(summary.rows == 2 && summary.copies == 3, "the deck's row stays where it is")
        #expect(try copies(container) == ["Trade|a": 5, "Trade|b": 1])

        let undo = UndoController(container: container)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Moved 2 Cards")
        #expect(undo.log.actions.first?.detail.contains("Main → Trade") == true)
        await undo.undo()
        #expect(undo.error == nil)
        #expect(try copies(container) == ["Main|a": 2, "Main|b": 1, "Trade|a": 3])
    }

    @Test func removeTakesTheSelectionInOneAction() async throws {
        let (container, ids) = try world()
        let summary = try CollectionEditController.remove(entryIDs: ids, in: ModelContext(container))
        #expect(summary.rows == 2)
        #expect(try copies(container) == ["Trade|a": 3])
        let undo = UndoController(container: container)
        await undo.refresh()
        await undo.undo()
        #expect(try copies(container) == ["Main|a": 2, "Main|b": 1, "Trade|a": 3])
    }

    @Test func movingIntoAListKeepsTheCopiesOutOfWhatIsOwned() async throws {
        let (container, ids) = try world()
        _ = try CollectionEditController.move(entryIDs: [ids[1]], to: "Wants", in: ModelContext(container))
        let owned = try await CollectionStore(modelContainer: container).ownedScryfallIDs()
        #expect(owned == ["a", "d"], "B left for the list; the deck's row is still owned")
    }
}
