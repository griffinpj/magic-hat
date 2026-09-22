import Testing
import Foundation
@testable import magic_hat

/// The in-memory evaluation a collection uses. Each clause must agree with
/// what `scryfallQuery` would ask Scryfall for.
@Suite("CardSearchQuery local matching")
struct CardSearchQueryMatchingTests {
    static func item(_ fields: [String: Any]) throws -> CardItem {
        var json: [String: Any] = [
            "id": UUID().uuidString, "name": "Test Card", "set": "tst", "set_name": "Test Set",
            "collector_number": "1", "rarity": "rare",
        ]
        fields.forEach { json[$0] = $1 }
        let data = try JSONSerialization.data(withJSONObject: json)
        return CardItem(scryfallCard: try JSONDecoder().decode(ScryfallCard.self, from: data), owned: true)
    }

    static let dragon: [String: Any] = [
        "name": "Nicol Bolas, the Ravager", "type_line": "Legendary Creature — Elder Dragon",
        "oracle_text": "Flying\nWhen Nicol Bolas enters, each opponent discards a card.",
        "mana_cost": "{1}{U}{B}{R}", "colors": ["U", "B", "R"], "color_identity": ["U", "B", "R"],
        "power": "4", "toughness": "4", "artist": "Svetlin Velinov", "set": "m19", "rarity": "mythic",
        "prices": ["usd": "18.04"], "legalities": ["modern": "legal", "standard": "not_legal"],
    ]

    @Test func emptyQueryMatchesEverything() throws {
        #expect(CardSearchQuery().matches(try Self.item(Self.dragon)))
        #expect(CardSearchQuery().matches(try Self.item([:])))
    }

    @Test func textWordsMatchAcrossNameTypeAndRulesText() throws {
        let card = try Self.item(Self.dragon)
        var q = CardSearchQuery()
        q.text = "nicol"
        #expect(q.matches(card))
        q.text = "elder dragon"
        #expect(q.matches(card), "words may land in the type line")
        q.text = "discards nicol"
        #expect(q.matches(card), "each word independently, any field")
        q.text = "nicol goblin"
        #expect(!q.matches(card), "every word must match somewhere")
    }

    @Test func formatsAndLanguage() throws {
        let card = try Self.item(Self.dragon)
        var q = CardSearchQuery()
        q.formats = [.modern]
        #expect(q.matches(card))
        q.formats = [.modern, .standard]
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.language = "ja"
        #expect(!q.matches(card), "search hits are English")
        q.language = "any"
        #expect(q.matches(card))
    }

    @Test func colorModesCountsAndColorless() throws {
        let card = try Self.item(Self.dragon)          // UBR
        var q = CardSearchQuery()
        q.colors = [.blue, .black, .red]
        #expect(q.matches(card))
        q.colors = [.blue, .black]
        #expect(!q.matches(card), "exactly: UB is not UBR")
        q.colorMode = .including
        #expect(q.matches(card))
        q.colorMode = .atMost
        #expect(!q.matches(card))
        q.colors = [.blue, .black, .red, .green]
        #expect(q.matches(card), "at most UBRG admits UBR")
        q = CardSearchQuery()
        q.minColors = 3; q.maxColors = 3
        #expect(q.matches(card))
        q.maxColors = 2
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.colorless = true
        #expect(!q.matches(card))
        #expect(q.matches(try Self.item(["colors": []])))
    }

    @Test func colorIdentityIsSeparate() throws {
        let card = try Self.item(["colors": [], "color_identity": ["G"], "type_line": "Land"])
        var q = CardSearchQuery()
        q.colors = [.green]
        #expect(!q.matches(card), "printed colours: none")
        q.useColorIdentity = true
        #expect(q.matches(card))
    }

    @Test func typeAndOracleTermsWithNegation() throws {
        let card = try Self.item(Self.dragon)
        var q = CardSearchQuery()
        q.typeLine = [TextTerm("Dragon"), TextTerm("Angel", negated: true)]
        #expect(q.matches(card))
        q.typeLine = [TextTerm("Dragon", negated: true)]
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.oracle = [TextTerm("flying"), TextTerm("trample", negated: true)]
        #expect(q.matches(card))
        q.oracle = [TextTerm("trample")]
        #expect(!q.matches(card))
    }

    @Test func manaCostContainsVersusExactly() throws {
        let card = try Self.item(Self.dragon)          // {1}{U}{B}{R}
        var q = CardSearchQuery()
        q.manaCost = "ub"
        #expect(q.matches(card))
        q.manaCost = "uu"
        #expect(!q.matches(card), "multiset: only one {U}")
        q.manaCost = "1ubr"
        q.manaCostMatch = .exactly
        #expect(q.matches(card))
        q.manaCost = "ubr"
        #expect(!q.matches(card))
    }

    @Test func setsRaritiesPriceStatsArtistFinish() throws {
        let card = try Self.item(Self.dragon)
        var q = CardSearchQuery()
        q.sets = ["M19"]
        #expect(q.matches(card))
        q.sets = ["clb"]
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.rarities = [.mythic, .rare]
        #expect(q.matches(card))
        q.rarities = [.common]
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.price = PriceRange(min: 10, max: 20)
        #expect(q.matches(card))
        q.price = PriceRange(min: 20, max: nil)
        #expect(!q.matches(card))
        #expect(!q.matches(try Self.item([:])), "no price never satisfies a price range")
        q = CardSearchQuery()
        q.stats = [StatConstraint(.manaValue, .equal, 4), StatConstraint(.power, .greaterOrEqual, 4),
                   StatConstraint(.toughness, .less, 5)]
        #expect(q.matches(card))
        q.stats = [StatConstraint(.loyalty, .equal, 4)]
        #expect(!q.matches(card), "a creature has no loyalty")
        q = CardSearchQuery()
        q.artist = "velinov"
        #expect(q.matches(card))
        q.artist = "Guay"
        #expect(!q.matches(card))
        q = CardSearchQuery()
        q.finishes = [.nonfoil]
        #expect(q.matches(card), "search hits and default rows are non-foil")
        q.finishes = [.foil]
        #expect(!q.matches(card))
    }

    @Test func colourLettersAreCanonical() {
        #expect(CardMeta.letters(["R", "u", "W"]) == "WUR")
        #expect(CardMeta.letters([]) == "")
        #expect(CardMeta.letters(nil) == nil)
        #expect(CardItem.colors(fromLetters: "WUR") == [.white, .blue, .red])
        #expect(CardItem.colors(fromLetters: nil).isEmpty)
    }
}
