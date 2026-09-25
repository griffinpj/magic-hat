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

    /// A "//" line that isn't a board is a comment — the type groups an
    /// export writes, or a note — never a card called "// Creatures".
    @Test func commentLinesAreSkipped() {
        let text = "// MAINBOARD\n// Creatures (2)\n1 Goblin Guide\n# a note\n1 Mountain\n// Instants (1)\n1 Lightning Bolt\n"
        let list = DeckListParser.parse(text)
        #expect(list.unparsed.isEmpty)
        #expect(list.lines.map(\.name) == ["Goblin Guide", "Mountain", "Lightning Bolt"])
    }

    // MARK: Export options

    static func snapshot() throws -> DeckSnapshot {
        func item(_ name: String, type: String, cost: String, price: String, set: String, number: String,
                  qty: Int = 1, board: DeckBoard = .main, built: Int = 0, available: Int = 0) throws -> DeckCardItem {
            let card = try CardSearchQueryMatchingTests.item([
                "name": name, "type_line": type, "mana_cost": cost, "prices": ["usd": price], "set": set, "collector_number": number,
            ])
            return DeckCardItem(id: UUID(), board: board, quantity: qty, card: card, builtQuantity: built, availableQuantity: available)
        }
        let commander = try item("Dáin of the Ancient Halls", type: "Legendary Creature — Dwarf", cost: "{3}{R}{W}", price: "55", set: "hoc", number: "104", board: .commander, built: 1)
        let creatures = DeckSection(id: "Creature", title: "Creatures", glyph: "creature", items: [
            try item("Bifur, Melodic Rider", type: "Legendary Creature — Dwarf", cost: "{2}{R}", price: "0.5", set: "hob", number: "147", built: 1),
            try item("Cavern-Hoard Dragon", type: "Creature — Dragon", cost: "{5}{R}{R}", price: "12", set: "ltc", number: "31"),
        ])
        let lands = DeckSection(id: "Land", title: "Lands", glyph: "land", items: [
            try item("Mountain", type: "Basic Land — Mountain", cost: "", price: "0.1", set: "sos", number: "278", qty: 15, built: 10, available: 3),
        ])
        let side = try item("Blasphemous Act", type: "Sorcery", cost: "{8}{R}", price: "3", set: "ltc", number: "211", board: .side)
        let maybe = try item("Arcane Signet", type: "Artifact", cost: "{2}", price: "1", set: "ltc", number: "273", board: .maybe)
        let items = [commander] + creatures.items + lands.items + [side, maybe]
        return DeckSnapshot(
            id: UUID(), name: "King under the Mountain", format: .commander, isLocked: false, notes: "",
            createdDate: Date(), updatedDate: Date(), identity: [.white, .red],
            commanders: [commander], sections: [creatures, lands], sideboard: [side], maybeboard: [maybe],
            stats: DeckStats.compute(played: [commander] + creatures.items + lands.items, format: .commander, identity: [.white, .red], allItems: items)
        )
    }

    @Test func defaultExportHasBoardHeadersAndPrintings() throws {
        let text = DeckListParser.export(try Self.snapshot())
        #expect(text == """
        // COMMANDER
        1 Dáin of the Ancient Halls (HOC) 104

        // MAINBOARD
        1 Bifur, Melodic Rider (HOB) 147
        1 Cavern-Hoard Dragon (LTC) 31
        15 Mountain (SOS) 278

        // SIDEBOARD
        1 Blasphemous Act (LTC) 211
        """)
        let back = DeckListParser.parse(text)
        #expect(back.copies(in: .main) == 17 && back.hasCommander && back.lines(in: .side).count == 1)
    }

    @Test func exportGroupsSortsAndDropsPrintings() throws {
        var options = DeckExportOptions()
        options.grouping = .type
        options.ordering = .price
        options.includesPrintings = false
        options.boards = [.main, .side, .maybe]
        let text = DeckListParser.export(try Self.snapshot(), options: options)
        #expect(text == """
        // COMMANDER
        1 Dáin of the Ancient Halls

        // MAINBOARD
        // Creatures (2)
        1 Cavern-Hoard Dragon
        1 Bifur, Melodic Rider

        // Lands (15)
        15 Mountain

        // SIDEBOARD
        1 Blasphemous Act

        // MAYBEBOARD
        1 Arcane Signet
        """)
        // The group lines come back as comments, so the export re-imports.
        let back = DeckListParser.parse(text)
        #expect(back.unparsed.isEmpty && back.copies(in: .main) == 17 && back.lines(in: .maybe).count == 1)
    }

    @Test func exportOnlyMissingIsAShoppingList() throws {
        var options = DeckExportOptions()
        options.onlyMissing = true
        options.boards = [.main]
        let text = DeckListParser.export(try Self.snapshot(), options: options)
        // Built and available copies are not missing; the commander is built.
        #expect(text == "// MAINBOARD\n1 Cavern-Hoard Dragon (LTC) 31\n2 Mountain (SOS) 278")
    }

    @Test func arenaExportUsesArenaHeadersOnly() throws {
        var options = DeckExportOptions()
        options.format = .arena
        options.grouping = .type
        options.ordering = .manaValue
        options.boards = [.main, .side, .maybe]
        let text = DeckListParser.export(try Self.snapshot(), options: options)
        #expect(text == """
        Commander
        1 Dáin of the Ancient Halls (HOC) 104

        Deck
        15 Mountain (SOS) 278
        1 Bifur, Melodic Rider (HOB) 147
        1 Cavern-Hoard Dragon (LTC) 31

        Sideboard
        1 Blasphemous Act (LTC) 211
        """)
        let back = DeckListParser.parse(text)
        #expect(back.hasCommander && back.copies(in: .main) == 17 && back.lines(in: .side).count == 1)
    }
}
