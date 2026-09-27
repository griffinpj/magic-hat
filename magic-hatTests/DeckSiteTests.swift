import Testing
import Foundation
@testable import magic_hat

/// Deck links: which site a link is, and each site's response shaped into
/// the text DeckListParser reads — against trimmed real responses.
@Suite("Deck sites")
struct DeckSiteTests {
    @Test func recognisesLinks() {
        #expect(DeckSite.recognise("https://archidekt.com/decks/123456/my_deck") == .archidekt(id: "123456"))
        #expect(DeckSite.recognise(" https://www.moxfield.com/decks/oEWXWHM5eEGMmopExLWRCA ") == .moxfield(id: "oEWXWHM5eEGMmopExLWRCA"))
        #expect(DeckSite.recognise("https://www.mtggoldfish.com/deck/6000000#paper") == .mtggoldfish(id: "6000000"))
        #expect(DeckSite.recognise("https://pastebin.com/raw/abc") == .plain(URL(string: "https://pastebin.com/raw/abc")!))
        #expect(DeckSite.recognise("4 Lightning Bolt") == nil)
        #expect(DeckSite.recognise("ftp://example.com/deck.txt") == nil)
    }

    @Test func archidektBecomesBoards() throws {
        let data = try Data(contentsOf: TestSupport.fixtureURL("archidekt-deck.json"))
        let deck = try DeckSiteClient.archidekt(data)
        #expect(deck.name == "Fun With Fungus")
        #expect(deck.format == .commander)
        let list = DeckListParser.parse(deck.text)
        #expect(list.lines(in: .commander).map(\.name) == ["Thelon of Havenwood"])
        #expect(list.lines(in: .commander).first?.setCode?.lowercased() == "tsp")
        #expect(list.copies(in: .main) == 5)
        let maybe = try #require(list.lines(in: .maybe).first)
        #expect(maybe.name == "Black Lotus" && maybe.isFoil)
    }

    @Test func mtggoldfishSideboardFollowsTheBlankLine() throws {
        let data = try Data(contentsOf: TestSupport.fixtureURL("mtggoldfish-deck.txt"))
        let deck = try DeckSiteClient.plainText(data, splitSideboardAtBlankLine: true)
        let list = DeckListParser.parse(deck.text)
        #expect(list.copies(in: .main) == 60)
        #expect(list.copies(in: .side) == 15)
        #expect(list.unparsed.isEmpty)
    }

    @Test func moxfieldBoards() throws {
        let json = """
        {"name":"Mox Deck","format":"commander","boards":{
          "commanders":{"cards":{"a":{"quantity":1,"card":{"name":"Atraxa, Praetors' Voice","set":"2xm","cn":"190"}}}},
          "mainboard":{"cards":{"b":{"quantity":1,"isFoil":true,"card":{"name":"Sol Ring","set":"c21","cn":"263"}}}},
          "tokens":{"cards":{"t":{"quantity":1,"card":{"name":"Poison Counter"}}}}}}
        """
        let deck = try DeckSiteClient.moxfield(Data(json.utf8))
        let list = DeckListParser.parse(deck.text)
        #expect(deck.name == "Mox Deck" && deck.format == .commander)
        #expect(list.lines(in: .commander).map(\.name) == ["Atraxa, Praetors' Voice"])
        #expect(list.lines(in: .main).map(\.name) == ["Sol Ring"] && list.lines(in: .main)[0].isFoil)
        #expect(list.totalCopies == 2, "tokens are not cards in the deck")
    }

    @Test func aWebPageIsNotAList() {
        #expect(throws: DeckSiteError.notAList) {
            try DeckSiteClient.plainText(Data("<!DOCTYPE html><html>…".utf8), splitSideboardAtBlankLine: false)
        }
    }
}
