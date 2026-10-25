import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// An edit that changes a row's identity (its finish) is recorded as the
/// old identity's copies leaving and the new one's arriving. Undoing it
/// rebuilds the old row from the first record's snapshot, so that
/// snapshot has to be the row as it was before the edit.
@MainActor
@Suite("Undoing an edit", .serialized)
struct CollectionEditUndoTests {
    @Test func undoingAFinishAndLanguageEditRestoresTheOldRow() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try ctx.save()
        try CollectionEditController.add(
            .init(printing: PrintingSelection(item: TestSupport.card(id: "e1", name: "Edited")),
                  collectionName: "Main", quantity: 2, finish: .normal, language: "de", purchasePrice: 3.5),
            context: ctx
        )
        let entry = try #require(try ctx.fetch(FetchDescriptor<CollectionEntry>()).first)

        try CollectionEditController.update(
            entryID: entry.id,
            edits: .init(quantity: 2, finish: .foil, condition: entry.condition, language: "ja", purchasePrice: 9),
            context: ctx
        )
        let edited = try #require(try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>()).first)
        #expect(edited.finish == .foil && edited.language == "ja" && edited.purchasePrice == 9)

        let undo = UndoController(container: container)
        await undo.refresh()
        await undo.undo()
        #expect(undo.error == nil)

        let rows = try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>())
        #expect(rows.count == 1, "the foil row is gone and the old row is back")
        let back = try #require(rows.first)
        #expect(back.finish == .normal)
        #expect(back.quantity == 2)
        #expect(back.language == "de", "the old language, not the edit's")
        #expect(back.purchasePrice == 3.5, "the old price paid, not the edit's")
    }
}
