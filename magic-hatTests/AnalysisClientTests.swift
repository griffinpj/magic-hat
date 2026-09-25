import Testing
import Foundation
@testable import magic_hat

/// The outside sources decode from what they actually send (trimmed real
/// responses in Fixtures/), and the shapes the app makes of them.
@Suite("AnalysisClients")
struct AnalysisClientTests {
    static func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let data = try Data(contentsOf: TestSupport.fixtureURL(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test func spellbookFindMyCombos() throws {
        let response = try Self.fixture("spellbook-find.json", as: SpellbookFindResponse.self)
        let results = response.results
        #expect(results.identity == "GWUB", "Spellbook writes the identity its own way")
        #expect(results.included.count == 1)
        let oracle = results.included[0]
        #expect(oracle.cardNames == ["Demonic Consultation", "Thassa's Oracle"])
        #expect(oracle.results.first == "Exile your library")
        #expect(oracle.bracketTag == "R" && oracle.manaNeeded == "{U}{U}{B}" && oracle.popularity == 149912)
        #expect(oracle.uses[0].card.oracleId == "9a1412db-45ad-46ea-8f12-a85d203113d8")
        #expect(oracle.legalities?["commander"] == true)

        let have: Set<String> = ["thassa's oracle", "demonic consultation", "sol ring", "isochron scepter", "atraxa, praetors' voice"]
        let set = CommanderSpellbookClient.comboSet(results, have: have)
        #expect(set.included.count == 1 && set.included[0].isTwoCard && set.included[0].isEarly)
        #expect(set.near.count == 4, "\(set.near.map(\.cards))")
        #expect(set.near.allSatisfy { $0.missing != nil })
        #expect(set.near.contains { $0.missing == "Hullbreaker Horror" })
        #expect(set.near.contains { $0.missing == "Dramatic Reversal" && $0.cards.contains("Isochron Scepter") })
        #expect(set.near.first!.popularity >= set.near.last!.popularity, "most played first")
        let tainted = set.near.first { $0.missing == "Tainted Pact" }!
        #expect(tainted.result == "exile your library" || tainted.result?.isEmpty == false)
    }

    @Test func spellbookVariantsForACard() throws {
        let page = try Self.fixture("spellbook-variants.json", as: SpellbookVariantPage.self)
        #expect(page.results.count == 3)
        #expect(page.results.allSatisfy { $0.cardNames.contains("Thassa's Oracle") })
        #expect(page.results.map { $0.cardNames.filter { $0 != "Thassa's Oracle" }.first! } == ["Demonic Consultation", "Tainted Pact", "Doomsday"])
    }

    @Test func recommander() throws {
        let response = try Self.fixture("recommander.json", as: RecommanderResponse.self)
        #expect(response.resultCode == "success" && response.error == nil)
        let rec = try #require(response.data?.recommendations.first)
        #expect(rec.name == "Goliath, Mass Manipulator" && rec.oracleID == "d06d7065-27e5-4119-a226-6f6d990d72c7")
        #expect(rec.score > 0.85 && rec.score < 0.86)
        let body = try JSONEncoder().encode(RecommanderRequest(commander: "A", partner: nil, deck: ["B"], cardFormat: "name"))
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("\"card_format\":\"name\"") && !json.contains("partner"), "a nil partner is left out: \(json)")
    }

    @Test func edhrecCommanderAndCardPages() throws {
        let commander = try Self.fixture("edhrec-commander.json", as: EDHRECPage.self)
        #expect(commander.hasSynergy)
        #expect(commander.card?.name == "Atraxa, Praetors' Voice" && commander.card?.rank == 4)
        #expect(commander.card?.salt ?? 0 > 1.7)
        let high = try #require(commander.cardlists.first { $0.tag == "highsynergycards" })
        #expect(high.cardviews.first?.name == "Tekuthal, Inquiry Dominus")
        #expect(high.cardviews.first?.id == "2d389264-e2d2-4589-9636-faa11fe46710", "the id is a Scryfall id")
        #expect(high.cardviews.first?.synergy ?? 0 > 0.27)
        #expect(high.cardviews.first?.inclusion ?? 0 > 0.6)

        let card = try Self.fixture("edhrec-card.json", as: EDHRECPage.self)
        #expect(!card.hasSynergy, "a card page carries lift, not synergy")
        #expect(card.card?.name == "Sol Ring")
        #expect(card.card?.inclusion ?? 0 > 0.8, "Sol Ring is in most decks")
        let top = try #require(card.cardlists.first { $0.tag == "topcards" })
        #expect(top.cardviews.allSatisfy { $0.lift != nil && $0.synergy == nil })
        let commanders = try #require(card.cardlists.first { $0.tag == "topcommanders" })
        #expect(commanders.cardviews.allSatisfy { $0.lift == nil })
    }

    @Test func edhrecSlugs() {
        #expect(EDHRECClient.slug(for: "Atraxa, Praetors' Voice") == "atraxa-praetors-voice")
        #expect(EDHRECClient.slug(for: "Thassa's Oracle") == "thassas-oracle")
        #expect(EDHRECClient.slug(for: "Snow-Covered Swamp") == "snow-covered-swamp")
        #expect(EDHRECClient.slug(for: "Bloomvine Regent // Claw-Tipped Hunter") == "bloomvine-regent")
        #expect(EDHRECClient.slug(for: "Ætherling") == "aetherling")
        #expect(EDHRECClient.slug(for: "Jace, the Mind Sculptor") == "jace-the-mind-sculptor")
        #expect(EDHRECClient.slug(for: "Sol Ring") == "sol-ring")
    }

    @Test func synergyReasonsReadAsShareOrRatio() {
        #expect(CardReason.synergy(0.82, commander: true).text == "+82% synergy")
        #expect(CardReason.synergy(-0.02, commander: true).text == "-2% synergy")
        #expect(CardReason.synergy(0.07, commander: false).text == "1.1× as often")
        #expect(CardReason.synergy(1.0, commander: false).text == "2× as often")
        #expect(CardReason.synergy(78.27, commander: false).text == "79× as often")
    }

    @Test func synergyQueryUsesTheCardsThemes() throws {
        let card = try DeckAnalysisTests.card("Blood Artist", type: "Creature — Vampire", text: "Whenever Blood Artist or another creature dies, target player loses 1 life and you gain 1 life.", cost: "{B}", colors: ["B"])
        let query = try #require(SynergyQuery.scryfall(for: card, identity: [.white, .black]))
        #expect(query.contains("o:dies") && query.contains("gain life"), "\(query)")
        #expect(query.contains("-name:\"blood artist\"") && query.contains("id<=wb") && query.contains("f:commander"), "\(query)")
        let open = try #require(SynergyQuery.scryfall(for: card, identity: nil))
        #expect(!open.contains("id<="))
        let colourless = try #require(SynergyQuery.scryfall(for: card, identity: []))
        #expect(colourless.contains("id<=c"))
        let bland = try DeckAnalysisTests.card("Bear", type: "Creature — Bear", cost: "{1}{G}", colors: ["G"])
        #expect(SynergyQuery.scryfall(for: bland, identity: nil) == nil, "nothing in the text to search on")
        let drawOnly = try DeckAnalysisTests.card("Divination", type: "Sorcery", text: "Draw two cards.", cost: "{2}{U}", colors: ["U"])
        #expect(SynergyQuery.themes(of: CardReading(drawOnly, identity: [.blue])) == ["card draw"], "a broad theme is used only when nothing specific is there")
    }

    @Test func diskCacheKeysAndHashes() {
        #expect(DiskJSONCache.safeName("combos-abc123") == "combos-abc123")
        #expect(DiskJSONCache.safeName("card:\"Thassa's Oracle\"").count == 64, "unsafe keys are hashed")
        #expect(DiskJSONCache.hash("a") == DiskJSONCache.hash("a") && DiskJSONCache.hash("a") != DiskJSONCache.hash("b"))
    }
}
