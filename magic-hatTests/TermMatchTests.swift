import Testing
import Foundation
@testable import magic_hat

@Suite("And / or between terms")
struct TermMatchTests {
    @Test func scryfallSyntax() {
        var q = CardSearchQuery()
        q.typeLine = [TextTerm("Dragon"), TextTerm("Elder"), TextTerm("Legendary", negated: true)]
        #expect(q.scryfallQuery.contains("t:dragon t:elder -t:legendary") || q.scryfallQuery.contains("t:Dragon t:Elder -t:Legendary"))
        q.typeLineMatch = .any
        #expect(q.scryfallQuery.contains("(t:Dragon or t:Elder) -t:Legendary"), "\(q.scryfallQuery)")
        q.oracle = [TextTerm("flying"), TextTerm("draw a card")]
        q.oracleMatch = .any
        #expect(q.scryfallQuery.contains("(o:flying or o:\"draw a card\")"), "\(q.scryfallQuery)")
        #expect(q.summary.contains("Dragon or Elder, not Legendary"), "\(q.summary)")
    }

    @Test func inMemoryMatching() {
        let dragon = CardItem(id: "d", scryfallID: "d", oracleID: nil, name: "Scion", setCode: "x", setName: "X", collectorNumber: "1",
                          rarity: "rare", quantity: 1, finish: .normal, condition: "near_mint", language: "en", addedDate: nil,
                          owned: true, collectionName: "Main", imageURL: nil, artCropURL: nil, aspectRatio: 1,
                          typeLine: "Legendary Creature — Elder Dragon", manaCost: nil, oracleText: "Flying", power: nil,
                          toughness: nil, loyalty: nil, colors: [], colorIdentity: [], artist: nil, price: nil, priceFoil: nil,
                          sortKey: "scion", collectorNumberValue: 1, rarityRankValue: 2, purchasePrice: nil,
                          legalities: nil, edhrecRank: nil, purchaseURIs: nil)
        var q = CardSearchQuery()
        q.typeLine = [TextTerm("Dragon"), TextTerm("Elder")]
        #expect(q.matches(dragon), "dragon and elder")
        q.typeLine = [TextTerm("Dragon"), TextTerm("Wizard")]
        #expect(!q.matches(dragon), "dragon and wizard")
        q.typeLineMatch = .any
        #expect(q.matches(dragon), "dragon or wizard")
        q.typeLine.append(TextTerm("Legendary", negated: true))
        #expect(!q.matches(dragon), "an exclusion still applies under or")
    }

    @Test func savedSearchesFromBeforeStillDecode() throws {
        var q = CardSearchQuery()
        q.typeLine = [TextTerm("Dragon")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(q)) as! [String: Any]
        json.removeValue(forKey: "typeLineMatchValue")
        json.removeValue(forKey: "oracleMatchValue")
        let old = try JSONDecoder().decode(CardSearchQuery.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.typeLineMatch == .all && old.typeLine.count == 1)
    }
}
