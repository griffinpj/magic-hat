import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("ImportController", .serialized)
@MainActor
struct ImportControllerTests {
    private func entries(_ ctx: ModelContext, in collection: String) throws -> [CollectionEntry] {
        try ctx.fetch(FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.collectionName == collection }
        ))
    }

    /// The reason binders left the model: the same printing from two binders
    /// must be one row whose quantity is the sum.
    @Test func samePrintingFromTwoBindersBecomesOneRow() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        let rows = [
            TestSupport.row(binder: "Library", id: "forest", quantity: 2),
            TestSupport.row(binder: "dragons", id: "forest", quantity: 1),
        ]
        let summary = try await ImportController.apply(
            rows: rows, selectedBinders: ["Library", "dragons"],
            collectionName: "Main", mode: .add, context: ctx
        ) { _ in }

        let result = try entries(ctx, in: "Main")
        #expect(result.count == 1)
        #expect(result.first?.quantity == 3)
        #expect(summary.added == 3)

        let audits = try ctx.fetch(FetchDescriptor<AuditRecord>())
        #expect(audits.count == 2)
        #expect(Set(audits.map(\.actionID)).count == 1)
        #expect(audits.map(\.quantityDelta).sorted() == [1, 2])
    }

    @Test func unselectedBindersAreIgnored() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        let rows = [
            TestSupport.row(binder: "Library", id: "a", quantity: 1),
            TestSupport.row(binder: "Wanted", id: "b", name: "Bolt", quantity: 4),
        ]
        _ = try await ImportController.apply(
            rows: rows, selectedBinders: ["Library"],
            collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        #expect(try entries(ctx, in: "Main").map(\.scryfallID) == ["a"])
    }

    @Test func differentFinishOrConditionStaysSeparate() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        let rows = [
            TestSupport.row(binder: "L", id: "x", finish: "normal", quantity: 1),
            TestSupport.row(binder: "L", id: "x", finish: "foil", quantity: 1),
            TestSupport.row(binder: "L", id: "x", finish: "normal", quantity: 1, condition: "played"),
        ]
        _ = try await ImportController.apply(
            rows: rows, selectedBinders: ["L"],
            collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        #expect(try entries(ctx, in: "Main").count == 3)
    }

    @Test func addMergesIntoAnExistingCollection() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        _ = try await ImportController.apply(
            rows: [TestSupport.row(binder: "A", id: "x", quantity: 1)],
            selectedBinders: ["A"], collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        _ = try await ImportController.apply(
            rows: [TestSupport.row(binder: "B", id: "x", quantity: 2)],
            selectedBinders: ["B"], collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        let result = try entries(ctx, in: "Main")
        #expect(result.count == 1)
        #expect(result.first?.quantity == 3)
    }

    @Test func replaceClearsTheWholeCollection() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        _ = try await ImportController.apply(
            rows: [TestSupport.row(binder: "A", id: "old1", quantity: 1),
                   TestSupport.row(binder: "A", id: "old2", quantity: 5)],
            selectedBinders: ["A"], collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        let summary = try await ImportController.apply(
            rows: [TestSupport.row(binder: "Z", id: "new", quantity: 1)],
            selectedBinders: ["Z"], collectionName: "Main", mode: .replace, context: ctx
        ) { _ in }
        let result = try entries(ctx, in: "Main")
        #expect(result.map(\.scryfallID) == ["new"])
        #expect(summary.removed == 6)
        let removals = try ctx.fetch(FetchDescriptor<AuditRecord>()).filter { $0.quantityDelta < 0 }
        #expect(removals.map(\.quantityDelta).sorted() == [-5, -1])
    }

    @Test func entriesAreLinkedToSharedCardMeta() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        _ = try await ImportController.apply(
            rows: [TestSupport.row(binder: "A", id: "x", quantity: 1, price: 1),
                   TestSupport.row(binder: "A", id: "x", finish: "foil", quantity: 1, price: 1)],
            selectedBinders: ["A"], collectionName: "Main", mode: .add, context: ctx
        ) { _ in }
        let result = try entries(ctx, in: "Main")
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.card != nil })
        #expect(try ctx.fetch(FetchDescriptor<CardMeta>()).count == 1)
    }
}
