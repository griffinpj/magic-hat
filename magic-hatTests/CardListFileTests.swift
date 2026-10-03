import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// The import reader against a sample of every file it claims to read
/// (`Fixtures/import-*`): the shape is recognised from the text, and each
/// row carries what its source knew.
@Suite("CardListFile")
struct CardListFileTests {
    private func read(_ name: String) throws -> CardListFile {
        let data = try Data(contentsOf: try TestSupport.fixtureURL(name))
        return CardListReader.read(try #require(String(data: data, encoding: .utf8)))
    }

    private func card(_ file: CardListFile, _ name: String) throws -> ImportedCard {
        try #require(file.cards.first { $0.name == name }, "no \(name) in \(file.cards.map(\.name))")
    }

    @Test func moxfield() throws {
        let file = try read("import-moxfield.csv")
        #expect(file.kind == .table(source: "Moxfield CSV") && file.cards.count == 3 && file.totalCopies == 7)
        let bolt = try card(file, "Lightning Bolt")
        #expect(bolt.quantity == 4 && bolt.setCode == "m11" && bolt.collectorNumber == "149" && bolt.finish == .normal)
        #expect(bolt.condition == "near_mint" && bolt.language == "en" && bolt.purchasePrice == 1.25)
        let jace = try card(file, "Jace, the Mind Sculptor")
        #expect(jace.finish == .foil && jace.condition == "lightly_played", "a quoted comma stays in the name")
        let ring = try card(file, "Sol Ring")
        #expect(ring.finish == .etched && ring.language == "de" && ring.purchasePrice == nil)
    }

    @Test func archidekt() throws {
        let file = try read("import-archidekt.csv")
        #expect(file.kind == .table(source: "Archidekt CSV") && file.totalCopies == 5)
        let study = try card(file, "Rhystic Study")
        #expect(study.scryfallID == "d32b3d83-4d0b-4b5f-a4fb-8bd7f5b8c8cb" && study.setCode == "jmp" && study.setName == "Jumpstart")
        #expect(try card(file, "Counterspell").finish == .foil)
        let thorin = try card(file, "Thorin, Company's Leader")
        #expect(thorin.finish == .etched && thorin.condition == "moderately_played" && thorin.language == "ja")
        #expect(thorin.scryfallID == nil && thorin.collectorNumber == nil)
        #expect(file.exactPrintings == 2)
    }

    @Test func deckbox() throws {
        let file = try read("import-deckbox.csv")
        #expect(file.kind == .table(source: "Deckbox CSV"))
        #expect(file.cards.map(\.name) == ["Birds of Paradise", "Borborygmos, Enraged", "Swords to Plowshares"], "a zero count is not a row")
        let birds = try card(file, "Birds of Paradise")
        #expect(birds.setCode == "m11" && birds.setName == "Magic 2011" && birds.collectorNumber == "165" && birds.purchasePrice == 4.5)
        let borborygmos = try card(file, "Borborygmos, Enraged")
        #expect(borborygmos.finish == .foil && borborygmos.condition == "lightly_played")
        let swords = try card(file, "Swords to Plowshares")
        #expect(swords.condition == "moderately_played" && swords.language == "de" && swords.purchasePrice == 1234.5)
    }

    @Test func dragonShield() throws {
        let file = try read("import-dragonshield.csv")
        #expect(file.kind == .table(source: "Dragon Shield CSV") && file.cards.count == 3, "the sep= line and CRLF endings")
        let elves = try card(file, "Llanowar Elves")
        #expect(elves.quantity == 3 && elves.setCode == "dom" && elves.collectorNumber == "168" && elves.purchasePrice == 0.25)
        let sheoldred = try card(file, "Sheoldred, the Apocalypse")
        #expect(sheoldred.finish == .foil && sheoldred.language == "ja" && sheoldred.condition == "lightly_played")
        #expect(try card(file, "Urza, Lord High Artificer").condition == "moderately_played")
    }

    @Test func tcgplayer() throws {
        let file = try read("import-tcgplayer.csv")
        #expect(file.kind == .table(source: "TCGplayer CSV"))
        let ring = try card(file, "Sol Ring")
        #expect(ring.quantity == 2 && ring.setCode == "cmm" && ring.collectorNumber == "410" && ring.finish == .foil,
                "the treatment comes off the name, the # off the number")
        #expect(ring.purchasePrice == nil, "Price is the market's, not what was paid")
        #expect(try card(file, "Fire // Ice").collectorNumber == "290")
        #expect(try card(file, "Erebos's Intervention").quantity == 4)
    }

    @Test func delverLensWithSemicolons() throws {
        let file = try read("import-delverlens.csv")
        #expect(file.kind == .table(source: "Delver Lens CSV"))
        let brainstorm = try card(file, "Brainstorm")
        #expect(brainstorm.quantity == 4 && brainstorm.setCode == "sta" && brainstorm.collectorNumber == "13")
        let force = try card(file, "Force of Will")
        #expect(force.finish == .foil && force.condition == "lightly_played" && force.language == "it")
    }

    @Test func deckstatsMTGGoldfishAndCardKingdom() throws {
        let deckstats = try read("import-deckstats.csv")
        #expect(deckstats.kind == .table(source: "Deckstats CSV"))
        let path = try card(deckstats, "Path to Exile")
        #expect(path.quantity == 2 && path.setCode == "2xm" && path.collectorNumber == "25", "set_code, not the numeric set_id")
        #expect(try card(deckstats, "Mox Opal").finish == .foil)

        let goldfish = try read("import-mtggoldfish.csv")
        #expect(goldfish.kind == .table(source: "MTGGoldfish CSV"))
        #expect(try card(goldfish, "Thoughtseize").quantity == 4 && (try card(goldfish, "Thoughtseize").setCode) == "ths")
        #expect(try card(goldfish, "Tarmogoyf").finish == .foil)
        #expect(try card(goldfish, "Thoughtseize").finish == .normal, "REGULAR is not foil")

        let kingdom = try read("import-cardkingdom.csv")
        let vampiric = try card(kingdom, "Vampiric Tutor")
        #expect(vampiric.quantity == 2 && vampiric.finish == .foil && vampiric.setName == "Eternal Masters" && vampiric.setCode == nil)
        #expect(try card(kingdom, "Demonic Tutor").finish == .normal)
    }

    @Test func aSpreadsheetWithTabsAndOneWithNoHeader() throws {
        let sheet = try read("import-spreadsheet.tsv")
        #expect(sheet.kind == .table(source: "Spreadsheet"))
        let ritual = try card(sheet, "Dark Ritual")
        #expect(ritual.quantity == 4 && ritual.setName == "Mystical Archive" && ritual.setCode == nil && ritual.finish == .normal)
        let snapcaster = try card(sheet, "Snapcaster Mage")
        #expect(snapcaster.setCode == "isd" && snapcaster.finish == .foil, "Set is a code when written as one")

        let plain = try read("import-plain.csv")
        #expect(plain.cards.map(\.name) == ["Swords to Plowshares", "Wrath of God", "Elesh Norn, Grand Cenobite"])
        #expect(plain.cards.map(\.quantity) == [4, 2, 1])
    }

    @Test func mtgoDek() throws {
        let file = try read("import-mtgo.dek")
        #expect(file.kind == .mtgoDek && file.totalCopies == 10)
        #expect(file.cards.map(\.name) == ["Ragavan, Nimble Pilferer", "Lightning Bolt", "Fire & Ice"])
    }

    @Test func aTextListInEveryShape() throws {
        let file = try read("import-list.txt")
        #expect(file.kind == .text && file.unparsed.isEmpty, "unparsed: \(file.unparsed)")
        func find(_ name: String, set: String? = nil) throws -> ImportedCard {
            try #require(file.cards.first { $0.name == name && (set == nil || $0.setCode == set) }, "\(name): \(file.cards.map(\.name))")
        }
        #expect(try find("Lightning Bolt").quantity == 4)
        #expect(try find("Counterspell").quantity == 4)
        #expect(try find("Sol Ring", set: nil).quantity == 2, "a trailing x2")
        #expect(try find("Arcane Signet").quantity == 1, "a bullet")
        let coat = try find("Mithril Coat")
        #expect(coat.setCode == "ltr" && coat.collectorNumber == "245" && coat.finish == .foil)
        #expect(try find("Sol Ring", set: "cmm").finish == .etched)
        #expect(try find("Brainstorm").setCode == "sta" && (try find("Brainstorm").quantity) == 2, "[STA] is a set")
        let study = try find("Rhystic Study")
        #expect(study.setCode == "jmp" && study.collectorNumber == "169", "[Draw] and ^tags^ are dropped")
        #expect(try find("Opt").quantity == 3, "a tab between count and name")
        #expect(try find("Thorin, Company's Leader").quantity == 1)
        #expect(try find("Pyroblast").quantity == 2, "SB: prefix")
        #expect(file.cards.count == 11)
    }

    @Test func aListWithCommasIsNotATable() {
        let file = CardListReader.read("1 Thorin, Company's Leader\n1 Glóin, Dwarf Emissary\n4 Mountain\n")
        #expect(file.kind == .text && file.cards.map(\.name) == ["Thorin, Company's Leader", "Glóin, Dwarf Emissary", "Mountain"])
        #expect(CardListReader.read("").isEmpty && CardListReader.read("\u{FEFF}Name,Qty\nOpt,2\n").totalCopies == 2, "a BOM is skipped")
    }

    @Test func theRealManaBoxExportIsRecognised() throws {
        let file = try read("ManaBox_Collection.csv")
        #expect(file.isManaBox && file.cards.count == 3872 && file.totalCopies == 6563)
        #expect(file.exactPrintings == 3872, "every row carries its Scryfall id")
    }

    @Test func valuesAcrossVocabularies() {
        #expect(CardListReader.number(in: "$1,234.50") == 1234.5 && CardListReader.number(in: "3,20 €") == 3.2)
        #expect(CardListReader.number(in: "") == nil)
        #expect(CardListReader.finish("Foil Etched") == .etched && CardListReader.finish("nonfoil") == .normal)
        #expect(CardListReader.finish("TRUE") == .foil && CardListReader.finish("") == .normal)
        #expect(CardListReader.condition("NM-Mint") == "near_mint" && CardListReader.condition("heavily_played") == "heavily_played")
        #expect(CardListReader.language("Japanese") == "ja" && CardListReader.language("zhs") == "zhs" && CardListReader.language("Klingon") == nil)
        #expect(CardListReader.cleanName("Sol Ring (Extended Art)") == "Sol Ring")
        #expect(CardListReader.cleanName("Erase (Not the Urza's Legacy One)") == "Erase (Not the Urza's Legacy One)")
        #expect(CardListReader.cleanName("Fire / Ice") == "Fire // Ice")
        #expect(CollectionImportController.setCodes(byName: [("Magic 2011", "M11")])[CollectionImportController.foldSetName("magic 2011")] == "m11")
    }
}

/// Rows into a collection: matched by id, by printing, by name in the set
/// named, by name — and what the row said about itself kept.
@MainActor
@Suite("Import rows into a collection", .serialized)
struct CollectionImportControllerTests {
    @Test func rowsMatchByTheBestThingTheyCarry() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        for (id, name, set, number) in [("11111111-1111-4111-8111-111111111111", "Sol Ring", "c21", "263"),
                                        ("s2", "Sol Ring", "cmm", "410"), ("b1", "Lightning Bolt", "m11", "146")] {
            let meta = CardMeta(scryfallID: id, name: name, setCode: set, setName: set.uppercased(), collectorNumber: number,
                                rarity: "rare", fetchState: .fetched)
            meta.oracleID = "o-\(name)"
            meta.priceUSD = 1
            meta.priceUSDFoil = 3
            ctx.insert(meta)
        }
        try ctx.save()
        let csv = """
        Quantity,Name,Set Code,Collector Number,Foil,Condition,Language,Scryfall ID,Purchase Price
        2,Sol Ring,,,,,,11111111-1111-4111-8111-111111111111,0.5
        1,Sol Ring,CMM,,foil,LP,German,,
        3,Lightning Bolt,M11,146,,,,,
        1,Not A Real Card,,,,,,,
        """
        let file = CardListReader.read(csv)
        let outcome = try await CollectionImportController.importCards(file.cards, into: "Main", container: container, remote: false)
        #expect(outcome.copies == 6 && outcome.rows == 3 && outcome.unresolved == ["Not A Real Card"])
        let rows = try ModelContext(container).fetch(FetchDescriptor<CollectionEntry>())
        let byID = try #require(rows.first { $0.scryfallID == "11111111-1111-4111-8111-111111111111" })
        #expect(byID.quantity == 2 && byID.purchasePrice == 0.5, "matched by its id, the price paid kept")
        let inSet = try #require(rows.first { $0.scryfallID == "s2" }, "the name in the set the row names")
        #expect(inSet.finish == .foil && inSet.condition == "lightly_played" && inSet.language == "de")
        #expect(inSet.purchasePrice == 3, "no price in the file: today's, for the finish")
        #expect(rows.first { $0.scryfallID == "b1" }?.quantity == 3)
        let actions = Set(try ModelContext(container).fetch(FetchDescriptor<AuditRecord>()).map(\.actionID))
        #expect(actions.count == 1, "one History action")
    }
}
