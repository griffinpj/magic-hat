import Testing
import Foundation
@testable import magic_hat

/// The query builder is the contract with Scryfall; each filter must land
/// in the syntax the docs describe, and nothing may leak into an empty query.
@Suite("CardSearchQuery → Scryfall syntax")
struct CardSearchQueryTests {
    @Test func emptyQueryIsEmpty() {
        let q = CardSearchQuery()
        #expect(q.isEmpty)
        #expect(!q.hasFilters)
        #expect(q.activeFilterCount == 0)
        // Only the extras default is emitted; it narrows nothing the user chose.
        #expect(q.scryfallQuery == "-is:funny")
    }

    @Test func textPassesThroughAndSyntaxIsPreserved() {
        var q = CardSearchQuery()
        q.text = "  ancient dragon t:legendary "
        #expect(q.scryfallQuery.hasPrefix("ancient dragon t:legendary"))
        #expect(!q.isEmpty)
        #expect(q.activeFilterCount == 0, "text is not a filter")
    }

    @Test func formatsColorsAndCounts() {
        var q = CardSearchQuery()
        q.formats = [.modern, .commander]
        q.colors = [.red, .green]
        q.colorMode = .including
        q.minColors = 2
        q.maxColors = 3
        let s = q.scryfallQuery
        #expect(s.contains("legal:commander"))
        #expect(s.contains("legal:modern"))
        #expect(s.contains("c>=rg"), "WUBRG order, lowercase")
        #expect(s.contains("c>=2"))
        #expect(s.contains("c<=3"))
        #expect(q.activeFilterCount == 2)
    }

    @Test func colorIdentityAndExactCount() {
        var q = CardSearchQuery()
        q.useColorIdentity = true
        q.colors = [.white, .blue]
        q.minColors = 2
        q.maxColors = 2
        let s = q.scryfallQuery
        #expect(s.contains("id=wu"))
        #expect(s.contains("id=2"))
        #expect(!s.contains("id>="))
    }

    @Test func colorlessOnlyWhenNoColors() {
        var q = CardSearchQuery()
        q.colorless = true
        #expect(q.scryfallQuery.contains("c=c"))
        q.colors = [.black]
        #expect(!q.scryfallQuery.contains("c=c"))
        #expect(q.scryfallQuery.contains("c=b"))
    }

    @Test func typeLineAndOracleTermsQuoteAndNegate() {
        var q = CardSearchQuery()
        q.typeLine = [TextTerm("Legendary"), TextTerm("Elder Dragon"), TextTerm("Angel", negated: true)]
        q.oracle = [TextTerm("draw a card"), TextTerm("flying", negated: true)]
        let s = q.scryfallQuery
        #expect(s.contains("t:Legendary"))
        #expect(s.contains("t:\"Elder Dragon\""))
        #expect(s.contains("-t:Angel"))
        #expect(s.contains("o:\"draw a card\""))
        #expect(s.contains("-o:flying"))
    }

    @Test func manaCostNormalisesLooseInput() {
        #expect(CardSearchQuery.normalizedManaCost("2gw") == "{2}{G}{W}")
        #expect(CardSearchQuery.normalizedManaCost("{2}{G/W}x") == "{2}{G/W}{X}")
        #expect(CardSearchQuery.normalizedManaCost("wubrg") == "{W}{U}{B}{R}{G}")
        #expect(CardSearchQuery.normalizedManaCost("12") == "{12}")
        #expect(CardSearchQuery.normalizedManaCost(" - ") == "")
        var q = CardSearchQuery()
        q.manaCost = "2gw"
        #expect(q.scryfallQuery.contains("m:{2}{G}{W}"))
        q.manaCostMatch = .exactly
        #expect(q.scryfallQuery.contains("m={2}{G}{W}"))
    }

    @Test func setsRaritiesAreOrGroups() {
        var q = CardSearchQuery()
        q.sets = ["CLB"]
        #expect(q.scryfallQuery.contains("s:clb"))
        q.sets = ["clb", "afr"]
        #expect(q.scryfallQuery.contains("(s:afr or s:clb)"))
        q.rarities = [.mythic, .rare]
        #expect(q.scryfallQuery.contains("(r:rare or r:mythic)"), "rarity order low → high")
    }

    @Test func priceStatsFinishArtist() {
        var q = CardSearchQuery()
        q.price = PriceRange(min: 1.5, max: 20)
        q.stats = [StatConstraint(.power, .greaterOrEqual, 4), StatConstraint(.manaValue, .equal, 3)]
        q.finishes = [.foil]
        q.artist = "Rebecca Guay"
        let s = q.scryfallQuery
        #expect(s.contains("usd>=1.50"))
        #expect(s.contains("usd<=20"))
        #expect(s.contains("pow>=4"))
        #expect(s.contains("mv=3"))
        #expect(s.contains("is:foil"))
        #expect(s.contains("a:\"Rebecca Guay\""))
        #expect(q.activeFilterCount == 4)
    }

    @Test func extrasAndLanguage() {
        var q = CardSearchQuery()
        q.excludeExtras = false
        q.language = "ja"
        let s = q.scryfallQuery
        #expect(s.contains("include:extras"))
        #expect(!s.contains("-is:funny"))
        #expect(s.contains("lang:ja"))
    }

    @Test func sortDefaultsAndUnique() {
        var q = CardSearchQuery()
        #expect(q.effectiveDirection == .ascending)
        q.sort = .price
        #expect(q.effectiveDirection == .descending)
        q.direction = .ascending
        #expect(q.effectiveDirection == .ascending)
        #expect(q.unique == "cards")
        q.groupPrintings = false
        #expect(q.unique == "prints")
    }

    @Test func clearFiltersKeepsTextAndOptions() {
        var q = CardSearchQuery()
        q.text = "dragon"
        q.groupPrintings = false
        q.formats = [.modern]
        q.artist = "x"
        q.clearFilters()
        #expect(!q.hasFilters)
        #expect(q.text == "dragon")
        #expect(q.groupPrintings == false)
    }

    @Test func summaryAndSuggestedName() {
        var q = CardSearchQuery()
        #expect(q.summary == "All cards")
        q.text = "dragon"
        q.formats = [.modern]
        q.colors = [.red, .green]
        q.price = PriceRange(min: 10, max: nil)
        #expect(q.summary == "“dragon” · Modern · R/G · ≥ $10")
        #expect(q.suggestedName == "Dragon")
    }

    @Test func roundTripsThroughJSON() throws {
        var q = CardSearchQuery()
        q.text = "x"
        q.formats = [.pauper]
        q.typeLine = [TextTerm("Goblin", negated: true)]
        q.stats = [StatConstraint(.toughness, .less, 2)]
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(CardSearchQuery.self, from: data)
        #expect(back == q)
    }
}
