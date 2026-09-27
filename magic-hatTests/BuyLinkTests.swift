import Testing
import Foundation
@testable import magic_hat

@Suite("Buy links")
struct BuyLinkTests {
    @Test func linesMergeByNameAndUseTheFrontFace() {
        let lines = CardStore.lines([("Sol Ring", 1), ("Delver of Secrets // Insectile Aberration", 2), ("Sol Ring", 2), ("Island", 0)])
        #expect(lines == [BuyLine(name: "Sol Ring", quantity: 3), BuyLine(name: "Delver of Secrets", quantity: 2)])
    }

    @Test func tcgplayerMassEntry() throws {
        let url = try #require(CardStore.tcgplayer.url(for: [BuyLine(name: "Sol Ring", quantity: 1), BuyLine(name: "Counterspell", quantity: 4)]))
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "www.tcgplayer.com" && comps.path == "/massentry")
        #expect(comps.queryItems?.first { $0.name == "productline" }?.value == "Magic")
        #expect(comps.queryItems?.first { $0.name == "c" }?.value == "1 Sol Ring||4 Counterspell")
    }

    @Test func cardKingdomBuilder() throws {
        let url = try #require(CardStore.cardKingdom.url(for: [BuyLine(name: "R&D's Secret Lair", quantity: 1), BuyLine(name: "A+B", quantity: 2)]))
        #expect(url.absoluteString.hasPrefix("https://www.cardkingdom.com/builder?c="))
        #expect(url.absoluteString.contains("%26"), "an ampersand in a name is escaped")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.queryItems?.first { $0.name == "c" }?.value == "1 R&D's Secret Lair\n2 A+B")
    }

    @Test func nothingToBuyIsNoLink() {
        #expect(CardStore.tcgplayer.url(for: []) == nil)
        #expect(CardStore.cardKingdom.url(for: [BuyLine(name: "X", quantity: 0)]) == nil)
    }
}
