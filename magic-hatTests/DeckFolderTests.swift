import Testing
import Foundation
import SwiftData
@testable import magic_hat

@MainActor
@Suite("Deck folders", .serialized)
struct DeckFolderTests {
    @Test func treePathsAndContainment() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = DeckFolderTree(nodes: [
            .init(id: a, name: "Commander", parentID: nil),
            .init(id: b, name: "Mono Red", parentID: a),
            .init(id: c, name: "Aggro", parentID: b),
        ])
        #expect(tree.path(to: c).map(\.name) == ["Commander", "Mono Red", "Aggro"])
        #expect(tree.isInside(c, a) && tree.isInside(a, a) && !tree.isInside(a, c) && !tree.isInside(nil, a))
        #expect(tree.flattened().map { "\($0.depth)\($0.node.name)" } == ["0Commander", "1Mono Red", "2Aggro"])
    }

    @Test func deletingAFolderMovesItsContentsUp() throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        let outer = try DeckEditController.createFolder(named: "Outer", in: nil, context: ctx)
        let inner = try DeckEditController.createFolder(named: "Inner", in: outer.id, context: ctx)
        let nested = try DeckEditController.createFolder(named: "Nested", in: inner.id, context: ctx)
        let deck = try DeckEditController.createDeck(name: "D", format: .commander, commander: nil, context: ctx)
        try DeckEditController.moveDecks([deck.id], to: inner.id, context: ctx)

        try DeckEditController.deleteFolder(inner.id, context: ctx)
        #expect(deck.folderID == outer.id, "the deck survives, one level up")
        #expect(nested.parentID == outer.id)
        #expect(try ctx.fetch(FetchDescriptor<Deck>()).count == 1)
    }

    @Test func aFolderCantMoveIntoItself() throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        let outer = try DeckEditController.createFolder(named: "Outer", in: nil, context: ctx)
        let inner = try DeckEditController.createFolder(named: "Inner", in: outer.id, context: ctx)
        #expect(throws: DeckEditController.FolderError.self) {
            try DeckEditController.moveFolder(outer.id, to: inner.id, context: ctx)
        }
        try DeckEditController.moveFolder(inner.id, to: nil, context: ctx)
        #expect(inner.parentID == nil)
        #expect(throws: DeckEditController.FolderError.self) {
            try DeckEditController.createFolder(named: "  ", in: nil, context: ctx)
        }
    }

    @Test func dragPayloadsRoundTrip() {
        let id = UUID()
        #expect(DeckDragItem(payload: DeckDragItem.deck(id).payload) == .deck(id))
        #expect(DeckDragItem(payload: DeckDragItem.folder(id).payload) == .folder(id))
        #expect(DeckDragItem(payload: "Sol Ring") == nil)
    }
}
