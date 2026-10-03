import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// The tokens a deck needs: Scryfall's `all_parts` kept on the maker's
/// CardMeta, rolled up by token kind across the played boards, with the
/// token's own image when the catalog holds it.
@Suite("Deck tokens")
struct DeckTokenTests {
    @Test func scryfallPartsKeepOnlyTokensAndNotTheCardItself() throws {
        let json = """
        {"id":"k1","name":"Krenko, Mob Boss","set":"m20","set_name":"Core Set 2020","collector_number":"1","rarity":"rare",
         "all_parts":[
           {"object":"related_card","id":"k1","component":"combo_piece","name":"Krenko, Mob Boss","type_line":"Legendary Creature — Goblin Warrior","uri":"x"},
           {"object":"related_card","id":"t-gob","component":"token","name":"Goblin","type_line":"Token Creature — Goblin","uri":"x"},
           {"object":"related_card","id":"m1","component":"meld_part","name":"Other","type_line":"Creature","uri":"x"}
         ]}
        """
        let card = try JSONDecoder().decode(ScryfallCard.self, from: Data(json.utf8))
        #expect(card.tokenParts.map(\.id) == ["t-gob"])
        let raw = RelatedToken.encode(card.tokenParts)
        #expect(RelatedToken.decode(raw) == [RelatedToken(id: "t-gob", name: "Goblin", typeLine: "Token Creature — Goblin")])
        #expect(RelatedToken.decode("") == [] && RelatedToken.decode(nil) == [])
        let plain = try JSONDecoder().decode(ScryfallCard.self, from: Data("""
        {"id":"p","name":"Plain","set":"m20","set_name":"Core","collector_number":"2","rarity":"common"}
        """.utf8))
        #expect(plain.tokenParts.isEmpty && RelatedToken.encode(plain.tokenParts) == "")
    }

    @Test func collectRollsUpByKindAndCountsMakers() {
        let soldierA = RelatedToken(id: "s1", name: "Soldier", typeLine: "Token Creature — Soldier")
        let soldierB = RelatedToken(id: "s2", name: "Soldier", typeLine: "Token Creature — Soldier")
        let treasure = RelatedToken(id: "tr", name: "Treasure", typeLine: "Token Artifact — Treasure")
        let tokens = DeckToken.collect([
            ("Captain", [soldierA]),
            ("Elspeth", [soldierB, treasure]),
            ("Raise the Alarm", [soldierA]),
        ], images: ["s2": ("https://img/s2", "https://img/s2-art")])
        #expect(tokens.map(\.name) == ["Soldier", "Treasure"], "most makers first")
        #expect(tokens[0].makers == ["Captain", "Elspeth", "Raise the Alarm"])
        #expect(tokens[0].imageURL == "https://img/s2", "the first printing with an image, whichever card named it")
        #expect(tokens[0].kind == "Creature — Soldier")
        #expect(tokens[1].makers == ["Elspeth"] && tokens[1].imageURL == nil)
        #expect(DeckTokenText.makers(["A"]) == "Made by A")
        #expect(DeckTokenText.makers(["A", "B"]) == "Made by A and B")
        #expect(DeckTokenText.makers(["A", "B", "C"]) == "Made by A and 2 more")
    }

    @MainActor
    @Test func snapshotListsTheDecksTokensWithCatalogImages() async throws {
        let world = try DeckBuilderTests.makeWorld()
        let ctx = world.container.mainContext
        let metas = try ctx.fetch(FetchDescriptor<CardMeta>())
        for meta in metas {
            switch meta.scryfallID {
            case "c1": meta.relatedTokensRaw = "t-sold\tSoldier\tToken Creature — Soldier"
            case "a1": meta.relatedTokensRaw = "t-sold2\tSoldier\tToken Creature — Soldier\nt-trea\tTreasure\tToken Artifact — Treasure"
            default: meta.relatedTokensRaw = ""
            }
        }
        let token = CardMeta(scryfallID: "t-sold2", name: "Soldier", setCode: "ttst", setName: "Test Tokens",
                             collectorNumber: "1", rarity: "common", fetchState: .fetched)
        token.imageNormalURL = "https://img/soldier"
        ctx.insert(token)
        // A maybeboard card's tokens are not needed at the table.
        let maybe = CardMeta(scryfallID: "m1", name: "Maybe", setCode: "tst", setName: "Test", collectorNumber: "m1", rarity: "rare", fetchState: .fetched)
        maybe.relatedTokensRaw = "t-x\tSpirit\tToken Creature — Spirit"
        ctx.insert(maybe)
        let row = DeckCard(scryfallID: "m1", oracleID: "oracle-m", name: "Maybe", board: .maybe, quantity: 1)
        row.deck = world.deck
        ctx.insert(row)
        try ctx.save()

        let store = DeckStore(modelContainer: world.container)
        let snapshot = try #require(try await store.snapshot(deckID: world.deck.id))
        #expect(snapshot.tokens.map(\.name) == ["Soldier", "Treasure"])
        #expect(snapshot.tokens[0].makers == ["Captain", "Alpha"])
        #expect(snapshot.tokens[0].imageURL == "https://img/soldier")
        #expect(snapshot.tokens[1].makers == ["Alpha"])
    }
}
