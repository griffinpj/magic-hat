import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// List edits and the reads the deck screen makes of them: Set as
/// Commander as a swap, cards only the deck names reported for hydration,
/// front faces resolved in one pass, and the list's sort keys.
@Suite("Deck edits")
@MainActor
struct DeckEditTests {
    /// The builder's world with every CardMeta current, so only what a
    /// test leaves out counts as pending.
    private func world() throws -> DeckBuilderTests.World {
        let w = try DeckBuilderTests.makeWorld()
        for meta in try w.container.mainContext.fetch(FetchDescriptor<CardMeta>()) { meta.metaVersion = CardMeta.currentVersion }
        try w.container.mainContext.save()
        return w
    }

    private func rows(_ deck: Deck) -> [String: (board: DeckBoard, quantity: Int)] {
        var out: [String: (DeckBoard, Int)] = [:]
        for card in deck.cards { out["\(card.board.rawValue)|\(card.name)"] = (card.board, card.quantity) }
        return out
    }

    @Test func snapshotReportsCardsWithNoCatalogData() async throws {
        let w = try world()
        let ctx = w.container.mainContext
        // Added from a Scryfall search the catalog lacks: a row, no meta.
        let stray = DeckCard(scryfallID: "zz-missing", oracleID: "oracle-z", name: "Zed", board: .main, quantity: 1)
        stray.deck = w.deck
        ctx.insert(stray)
        try ctx.save()
        let snapshot = try #require(try await DeckStore(modelContainer: w.container).snapshot(deckID: w.deck.id))
        #expect(snapshot.pendingMetaIDs == ["zz-missing"])

        // An incomplete meta (stored before this build's fields) is pending too.
        let beta = try #require(try ctx.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.scryfallID == "b1" })).first)
        beta.metaVersion = 0
        try ctx.save()
        let again = try #require(try await DeckStore(modelContainer: w.container).snapshot(deckID: w.deck.id))
        #expect(again.pendingMetaIDs == ["b1", "zz-missing"])
    }

    @Test func setAsCommanderMovesTheOldCommanderToTheMainboard() throws {
        let w = try world()
        let ctx = w.container.mainContext
        let beta = try #require(w.deck.cards.first { $0.name == "Beta" })
        try DeckEditController.makeCommander(deckCardID: beta.id, artCropURL: "https://art/beta", context: ctx)
        let after = rows(w.deck)
        #expect(after["commander|Beta"]?.quantity == 1)
        #expect(after["main|Captain"]?.quantity == 1, "the old commander stays in the list")
        #expect(after["main|Beta"] == nil)
        #expect(after["main|Alpha"]?.quantity == 2)
        #expect(w.deck.cards.reduce(0) { $0 + $1.quantity } == 4, "nothing lost")
        #expect(w.deck.coverArtURL == "https://art/beta")
    }

    @Test func setAsCommanderTakesOneCopyAndMergesTheOldOne() throws {
        let w = try world()
        let ctx = w.container.mainContext
        // A second Captain already in the mainboard, and two Alphas.
        let extra = DeckCard(scryfallID: "c1", oracleID: "oracle-c", name: "Captain", board: .main, quantity: 1)
        extra.deck = w.deck
        ctx.insert(extra)
        try ctx.save()
        let alpha = try #require(w.deck.cards.first { $0.name == "Alpha" })
        try DeckEditController.makeCommander(deckCardID: alpha.id, context: ctx)
        let after = rows(w.deck)
        #expect(after["commander|Alpha"]?.quantity == 1)
        #expect(after["main|Alpha"]?.quantity == 1, "one copy of two goes up")
        #expect(after["main|Captain"]?.quantity == 2, "merged with the copy already there")
        #expect(w.deck.cards.filter { $0.board == .main && $0.name == "Captain" }.count == 1)
    }

    @Test func resolveMatchesFrontFacesInOnePass() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        for (id, name) in [("f1", "Bloomvine Regent // Claim Territory"), ("f2", "Fable of the Mirror-Breaker // Reflection of Kiki-Jiki"),
                           ("p1", "Plain Card")] {
            let meta = CardMeta(scryfallID: id, name: name, setCode: "tst", setName: "Test", collectorNumber: id, rarity: "rare", fetchState: .fetched)
            meta.oracleID = "o-\(id)"
            ctx.insert(meta)
        }
        try ctx.save()
        let lines = ["Bloomvine Regent", "Fable of the Mirror-Breaker", "Plain Card", "Claim Territory", "Nothing Here"].map {
            DeckListLine(quantity: 1, name: $0, setCode: nil, collectorNumber: nil, isFoil: false, board: .main, raw: $0)
        }
        let resolved = try await DeckStore(modelContainer: container).resolve(lines)
        let byName = Dictionary(uniqueKeysWithValues: resolved.map { ($0.line.name, $0.scryfallID) })
        #expect(byName["Bloomvine Regent"] == "f1")
        #expect(byName["Fable of the Mirror-Breaker"] == "f2")
        #expect(byName["Plain Card"] == "p1")
        #expect(byName["Claim Territory"] == .some(nil), "a back face is not a front face")
        #expect(byName["Nothing Here"] == .some(nil))
    }

    @Test func manaValueSortReadsEachCostOnceAndKeepsATotalOrder() throws {
        func card(_ id: String, _ name: String, _ cost: String?) throws -> CardItem {
            var fields: [String: Any] = ["id": id, "name": name]
            if let cost { fields["mana_cost"] = cost }
            return try CardSearchQueryMatchingTests.item(fields)
        }
        let cards = [try card("1", "Zed", "{2}{G}"), try card("2", "Ant", "{X}{R}"), try card("3", "Bee", nil),
                     try card("4", "Cat", "{2}{G}"), try card("5", "Dog", "{W/U}{W/U}")]
        let up = DeckCardSort.manaValue.apply(cards, card: { $0 }, direction: .ascending).map(\.name)
        #expect(up == ["Bee", "Ant", "Dog", "Cat", "Zed"], "0, 1, 2, then 3s by name")
        let down = DeckCardSort.manaValue.apply(cards, card: { $0 }, direction: .descending).map(\.name)
        #expect(down == ["Cat", "Zed", "Dog", "Ant", "Bee"], "ties still fall to name A–Z")
    }
}
