import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// End-to-end against the real ManaBox export. Numbers below were profiled
/// from the file itself; the dynamic checks recompute them from the parsed
/// rows so the test also holds if the fixture is ever swapped.
@Suite("Real ManaBox export", .serialized)
struct RealCollectionImportTests {

    @Test func parsesEveryRowDespiteCRLF() throws {
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        #expect(rows.count == 3872)
        #expect(Set(rows.map(\.binderName)).count == 8)
        #expect(rows.allSatisfy { !$0.scryfallID.isEmpty })
        #expect(rows.reduce(0) { $0 + $1.quantity } == 6563)
    }

    @Test @MainActor func importingAllBindersMergesCrossBinderDuplicates() async throws {
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext

        let summary = try await ImportController.apply(
            rows: rows,
            selectedBinders: Set(rows.map(\.binderName)),
            collectionName: "Library",
            mode: .add,
            context: ctx
        ) { _ in }

        // Expected shape, recomputed from the rows.
        let keys = Set(rows.map {
            CollectionEntry.mergeKey(scryfallID: $0.scryfallID, collectionName: "Library",
                                     finish: $0.finish.rawValue, condition: $0.condition)
        })
        let entries = try ctx.fetch(FetchDescriptor<CollectionEntry>())

        #expect(entries.count == keys.count)
        #expect(entries.count == 3846)                       // 3,872 rows → 3,846 rows
        #expect(entries.reduce(0) { $0 + $1.quantity } == 6563)
        #expect(summary.added == 6563)
        #expect(Set(entries.map(\.mergeKey)).count == entries.count, "no duplicate merge keys survive")

        // A printing that lived in both "Wanted" and "Library" is one row, qty 2.
        let crossBinder = try #require(entries.first {
            $0.scryfallID == "78ee2013-29dc-4879-9d59-1b492996d297"
                && $0.finish == .normal && $0.condition == "near_mint"
        })
        #expect(crossBinder.quantity == 2)

        // One audit record per source row, all under a single action.
        let audits = try ctx.fetch(FetchDescriptor<AuditRecord>())
        #expect(audits.count == 3872)
        #expect(Set(audits.map(\.actionID)) == [summary.actionID])

        // Every entry points at one shared CardMeta per Scryfall id.
        #expect(entries.allSatisfy { $0.card != nil })
        #expect(try ctx.fetch(FetchDescriptor<CardMeta>()).count == Set(rows.map(\.scryfallID)).count)
    }

    @Test @MainActor func selectingOneBinderImportsOnlyItsRows() async throws {
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext

        _ = try await ImportController.apply(
            rows: rows, selectedBinders: ["dragons"],
            collectionName: "Dragons", mode: .add, context: ctx
        ) { _ in }

        let wanted = rows.filter { $0.binderName == "dragons" }
        let entries = try ctx.fetch(FetchDescriptor<CollectionEntry>())
        #expect(entries.reduce(0) { $0 + $1.quantity } == wanted.reduce(0) { $0 + $1.quantity })
        #expect(Set(entries.map(\.scryfallID)) == Set(wanted.map(\.scryfallID)))
    }

    @Test @MainActor func storeSnapshotCoversTheWholeImport() async throws {
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        let container = try TestSupport.makeContainer()
        _ = try await ImportController.apply(
            rows: rows, selectedBinders: Set(rows.map(\.binderName)),
            collectionName: "Library", mode: .add, context: container.mainContext
        ) { _ in }

        let snapshot = try await CollectionStore.shared(for: container)
            .snapshot(collectionName: "Library", sort: .name)
        #expect(snapshot.items.count == 3846)
        // Nothing has been hydrated, so everything is pending and nothing is stale.
        #expect(Set(snapshot.pendingIDs) == Set(rows.map(\.scryfallID)))
        #expect(snapshot.stalePriceIDs.isEmpty)
        // Sorted by name with a total order: re-sorting is a no-op.
        #expect(CardSorting.sorted(snapshot.items, by: .name).map(\.id) == snapshot.items.map(\.id))
    }
}
