import Testing
import Foundation
@testable import magic_hat

@Suite("DeckListParser")
struct DeckListParserTests {
    static func fixture() throws -> String {
        try String(contentsOf: try TestSupport.fixtureURL("KingUnderTheMountain.txt"), encoding: .utf8)
    }

    @Test func parsesTheRealExport() throws {
        let list = DeckListParser.parse(try Self.fixture())
        #expect(list.unparsed.isEmpty, "unparsed: \(list.unparsed)")
        #expect(list.lines.count == 79)
        #expect(list.lines(in: .commander).map(\.name) == ["Dáin of the Ancient Halls"])
        #expect(list.copies(in: .main) == 99, "a 100-card deck less its commander")
        #expect(list.lines(in: .side).count == 2)
        #expect(list.lines(in: .maybe).count == 4)
        #expect(list.hasCommander)
        #expect(list.suggestedFormat == .commander)

        let commander = list.lines(in: .commander)[0]
        #expect(commander.setCode == "hoc" && commander.collectorNumber == "104")
        let mountain = try #require(list.lines.first { $0.name == "Mountain" })
        #expect(mountain.quantity == 15 && mountain.setCode == "sos" && mountain.collectorNumber == "278")
        let coat = try #require(list.lines.first { $0.name == "Mithril Coat" })
        #expect(coat.isFoil && coat.collectorNumber == "245")
        let signet = try #require(list.lines.first { $0.name == "Arcane Signet" })
        #expect(!signet.isFoil)
        #expect(list.lines.contains { $0.name == "Thorin, Company's Leader" }, "commas and apostrophes survive")
        #expect(list.lines.contains { $0.name == "Glóin, Dwarf Emissary" }, "diacritics survive")
    }

    @Test func readsOtherShapes() {
        let text = """
        About
        Name Goblins

        Deck
        4x Goblin Guide
        Lightning Bolt
        20 Mountain

        Sideboard
        2 Smash to Smithereens [foil]
        """
        let list = DeckListParser.parse(text)
        #expect(list.title == "Goblins")
        #expect(list.copies(in: .main) == 25)
        #expect(list.lines.first { $0.name == "Lightning Bolt" }?.quantity == 1)
        #expect(list.lines.first { $0.name == "Goblin Guide" }?.quantity == 4)
        let smash = list.lines(in: .side).first
        #expect(smash?.quantity == 2 && smash?.isFoil == true && smash?.name == "Smash to Smithereens")
        #expect(!list.hasCommander && list.suggestedFormat == .other)
    }

    @Test func exportRoundTrips() throws {
        let text = "// COMMANDER\n1 Dáin of the Ancient Halls (HOC) 104\n\n// MAINBOARD\n15 Mountain (SOS) 278\n"
        let list = DeckListParser.parse(text)
        #expect(list.lines.count == 2)
        #expect(list.lines[1].quantity == 15)
    }
}
