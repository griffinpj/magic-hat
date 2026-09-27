import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("Zip archive")
struct ZipArchiveTests {
    @Test func roundTrip() throws {
        var writer = ZipWriter()
        let big = Data(String(repeating: "Lightning Bolt\n", count: 2000).utf8)
        let random = Data((0..<512).map { _ in UInt8.random(in: 0...255) })
        writer.add("a.txt", big)
        writer.add("dir/b.bin", random)
        writer.add("empty", Data())
        let zip = writer.finish()
        #expect(zip.count < big.count, "text deflates")
        let reader = try ZipReader(zip)
        #expect(reader.entries.map(\.path) == ["a.txt", "dir/b.bin", "empty"])
        #expect(try reader.data(for: "a.txt") == big)
        #expect(try reader.data(for: "b.bin") == random, "found by last component")
        #expect(try reader.data(for: "empty") == Data())
        #expect(throws: ZipError.missing("nope")) { try reader.data(for: "nope") }
    }

    @Test func readsAZipMadeByZip() throws {
        let data = try Data(contentsOf: TestSupport.fixtureURL("sample.zip"))
        let reader = try ZipReader(data)
        #expect(String(decoding: try reader.data(for: "hello.txt"), as: UTF8.self).hasPrefix("Hello, Magic Hat!"))
        #expect(try reader.data(for: "tiny.txt") == Data("x".utf8))
    }

    @Test func damageIsCaught() throws {
        var writer = ZipWriter()
        writer.add("a.txt", Data(String(repeating: "abc", count: 100).utf8))
        var zip = writer.finish()
        #expect(throws: ZipError.notAZip) { try ZipReader(Data("not a zip at all, not even close".utf8)) }
        zip[40] ^= 0xFF   // inside the deflated payload
        let reader = try ZipReader(zip)
        #expect(throws: ZipError.self) { try reader.data(for: "a.txt") }
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926, "the standard check value")
    }
}

@MainActor
@Suite("Backup and restore", .serialized)
struct BackupTests {
    private func world() throws -> ModelContainer {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        try CollectionEditController.createCollection(named: "Wishlist", kind: .list, context: ctx)
        try CollectionEditController.add(.init(printing: PrintingSelection(item: TestSupport.card(id: "s1", name: "Sol Ring")),
                                               collectionName: "Main", quantity: 2, language: "de", purchasePrice: 1.5), context: ctx)
        try CollectionEditController.add(.init(printing: PrintingSelection(item: TestSupport.card(id: "s2", name: "Mox Opal")),
                                               collectionName: "Wishlist", quantity: 1, finish: .foil), context: ctx)
        let folder = try DeckEditController.createFolder(named: "Commander", in: nil, context: ctx)
        let deck = try DeckEditController.createDeck(name: "Atraxa", format: .commander, commander: nil, context: ctx)
        try DeckEditController.moveDecks([deck.id], to: folder.id, context: ctx)
        let card = DeckCard(scryfallID: "s1", oracleID: nil, name: "Sol Ring", board: .main, quantity: 1)
        card.deck = deck
        ctx.insert(card)
        var q = CardSearchQuery(); q.text = "dragon"
        ctx.insert(SavedSearch(name: "Dragons", query: q))
        try ctx.save()
        return container
    }

    @Test func aBackupRestoresEverythingIntoAnEmptyApp() async throws {
        let source = try world()
        let backup = try BackupController.snapshot(in: ModelContext(source), settings: ["settings.currency": "eur"], appVersion: "test")
        #expect(backup.manifest.copies == 3 && backup.manifest.decks == 1 && backup.manifest.historyRecords == 2)
        let zip = try backup.zipped()
        let read = try AppBackup.read(zip)
        #expect(read.entries == backup.entries)
        #expect(read.settings["settings.currency"] == "eur")
        let csv = try CSVParser.parseManaBox(AppBackup.manaBoxCSV(read.entries))
        #expect(csv.count == 2 && csv.contains { $0.binderName == "Main" && $0.quantity == 2 && $0.language == "de" })

        let target = try TestSupport.makeContainer()
        let tctx = target.mainContext
        tctx.insert(MTGCollection(name: "Old Stuff"))
        try tctx.save()
        try BackupController.restore(read, in: ModelContext(target))

        let fresh = ModelContext(target)
        #expect(Set(try fresh.fetch(FetchDescriptor<MTGCollection>()).map(\.name)) == ["Main", "Wishlist"], "replaced, not merged")
        #expect(try fresh.fetch(FetchDescriptor<MTGCollection>()).first { $0.name == "Wishlist" }?.kind == .list)
        let rows = try fresh.fetch(FetchDescriptor<CollectionEntry>())
        #expect(rows.count == 2 && rows.first { $0.scryfallID == "s1" }?.purchasePrice == 1.5)
        let deck = try #require(try fresh.fetch(FetchDescriptor<Deck>()).first)
        #expect(deck.cards.count == 1 && deck.folderID != nil)
        #expect(try fresh.fetch(FetchDescriptor<DeckFolder>()).first?.name == "Commander")
        #expect(try fresh.fetch(FetchDescriptor<SavedSearch>()).first?.query.text == "dragon")

        // The ledger came across whole, so History still undoes.
        let undo = UndoController(container: target)
        await undo.refresh()
        #expect(undo.undoTitle == "Undo Added Mox Opal")
        await undo.undo()
        #expect(undo.error == nil)
        #expect(try ModelContext(target).fetch(FetchDescriptor<CollectionEntry>()).count == 1)
    }

    @Test func aNewerFormatIsRefused() throws {
        var backup = try BackupController.snapshot(in: ModelContext(try world()), settings: [:], appVersion: "test")
        backup.manifest.format = BackupManifest.currentFormat + 1
        #expect(throws: AppBackup.ReadError.self) { try AppBackup.read(try backup.zipped()) }
    }

    @Test func schedule() {
        let now = Date()
        #expect(BackupFrequency.daily.isDue(last: nil, now: now))
        #expect(!BackupFrequency.daily.isDue(last: now.addingTimeInterval(-3600), now: now))
        #expect(BackupFrequency.weekly.isDue(last: now.addingTimeInterval(-8 * 24 * 3600), now: now))
        #expect(!BackupFrequency.off.isDue(last: nil, now: now))
    }
}
