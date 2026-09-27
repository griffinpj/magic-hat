//
//  AppBackup.swift
//  magic-hat
//
//  Everything the user has entered, as plain Codable records: collections
//  and lists, every owned row, decks and their lists and folders, the
//  History ledger and its branch names, saved searches, and the settings.
//  Not the card catalog, rulings or images — those are Scryfall's, and
//  come back by themselves (a restored row with no CardMeta is simply
//  pending, and hydration fills it in).
//
//  A backup is a zip of one JSON file per table plus a manifest, and a
//  ManaBox-format CSV of the collection for use anywhere else. JSON per
//  table rather than a copy of the SQLite store: it survives schema
//  changes (every field new since format 1 decodes as optional), it can be
//  read by eye (dates are Foundation's exact reference-date seconds), and
//  it is a few MB where the store with its catalog is hundreds.
//

import Foundation

nonisolated struct BackupManifest: Codable, Sendable, Equatable {
    static let currentFormat = 1
    static let fileName = "manifest.json"

    var format: Int
    var createdAt: Date
    var appVersion: String
    var collections: Int
    var entries: Int
    var copies: Int
    var decks: Int
    var historyRecords: Int
}

nonisolated struct AppBackup: Codable, Sendable {
    var manifest: BackupManifest
    var collections: [CollectionRecord]
    var entries: [EntryRecord]
    var decks: [DeckRecord]
    var deckCards: [DeckCardRecord]
    var folders: [FolderRecord]
    var audit: [AuditRecordValue]
    var branchNames: [BranchNameRecord]
    var savedSearches: [SavedSearchRecord]
    var settings: [String: String]

    struct CollectionRecord: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var createdDate: Date
        var kind: String?
    }

    struct EntryRecord: Codable, Sendable, Equatable {
        var id: UUID
        var scryfallID: String
        var collectionName: String
        var name: String
        var setCode: String
        var setName: String
        var collectorNumber: String
        var rarity: String
        var finish: String
        var quantity: Int
        var condition: String
        var language: String
        var purchasePrice: Double?
        var purchasePriceCurrency: String?
        var manaBoxID: String?
        var addedDate: Date?
        var sourceCollectionName: String?
    }

    struct DeckRecord: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var format: String
        var isLocked: Bool
        var notes: String
        var createdDate: Date
        var updatedDate: Date
        var coverArtURL: String?
        var folderID: UUID?
    }

    struct DeckCardRecord: Codable, Sendable, Equatable {
        var id: UUID
        var deckID: UUID
        var scryfallID: String
        var oracleID: String?
        var name: String
        var board: String
        var quantity: Int
        var addedDate: Date
    }

    struct FolderRecord: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var parentID: UUID?
        var createdDate: Date
    }

    struct AuditRecordValue: Codable, Sendable, Equatable {
        var id: UUID
        var actionID: UUID
        var action: String
        var timestamp: Date
        var scryfallID: String
        var cardName: String
        var collectionName: String
        var binderName: String
        var finish: String
        var condition: String
        var quantityDelta: Int
        var collectionEntryID: UUID?
        var undoesActionID: UUID?
        var setCode: String?
        var setName: String?
        var collectorNumber: String?
        var rarity: String?
        var language: String?
        var purchasePrice: Double?
        var purchasePriceCurrency: String?
        var manaBoxID: String?
        var addedDate: Date?
        var sourceCollectionName: String?
        var collectionKind: String?
    }

    struct BranchNameRecord: Codable, Sendable, Equatable {
        var actionID: UUID
        var name: String
    }

    struct SavedSearchRecord: Codable, Sendable, Equatable {
        var id: UUID
        var name: String
        var query: Data
        var createdDate: Date
        var lastUsedDate: Date
        var sortOrder: Int
    }
}

// MARK: - From the models

nonisolated extension AppBackup.CollectionRecord {
    init(_ c: MTGCollection) { self.init(id: c.id, name: c.name, createdDate: c.createdDate, kind: c.kindRaw) }
}

nonisolated extension AppBackup.EntryRecord {
    init(_ e: CollectionEntry) {
        self.init(id: e.id, scryfallID: e.scryfallID, collectionName: e.collectionName, name: e.name, setCode: e.setCode,
                  setName: e.setName, collectorNumber: e.collectorNumber, rarity: e.rarity, finish: e.finishRaw,
                  quantity: e.quantity, condition: e.condition, language: e.language, purchasePrice: e.purchasePrice,
                  purchasePriceCurrency: e.purchasePriceCurrency, manaBoxID: e.manaBoxID, addedDate: e.addedDate,
                  sourceCollectionName: e.sourceCollectionName)
    }

    func model() -> CollectionEntry {
        let e = CollectionEntry(id: id, scryfallID: scryfallID, collectionName: collectionName, name: name, setCode: setCode,
                                setName: setName, collectorNumber: collectorNumber, rarity: rarity,
                                finish: CardFinish(rawValue: finish) ?? .normal, quantity: quantity, condition: condition,
                                language: language, purchasePrice: purchasePrice, purchasePriceCurrency: purchasePriceCurrency,
                                manaBoxID: manaBoxID, addedDate: addedDate)
        e.sourceCollectionName = sourceCollectionName
        return e
    }
}

nonisolated extension AppBackup.DeckRecord {
    init(_ d: Deck) {
        self.init(id: d.id, name: d.name, format: d.formatRaw, isLocked: d.isLocked, notes: d.notes, createdDate: d.createdDate,
                  updatedDate: d.updatedDate, coverArtURL: d.coverArtURL, folderID: d.folderID)
    }

    func model() -> Deck {
        let d = Deck(id: id, name: name, format: DeckFormat(rawValue: format) ?? .other, notes: notes, createdDate: createdDate)
        d.isLocked = isLocked
        d.updatedDate = updatedDate
        d.coverArtURL = coverArtURL
        d.folderID = folderID
        return d
    }
}

nonisolated extension AppBackup.DeckCardRecord {
    init?(_ c: DeckCard) {
        guard let deck = c.deck else { return nil }
        self.init(id: c.id, deckID: deck.id, scryfallID: c.scryfallID, oracleID: c.oracleID, name: c.name,
                  board: c.boardRaw, quantity: c.quantity, addedDate: c.addedDate)
    }
}

nonisolated extension AppBackup.AuditRecordValue {
    init(_ r: AuditRecord) {
        self.init(id: r.id, actionID: r.actionID, action: r.actionRaw, timestamp: r.timestamp, scryfallID: r.scryfallID,
                  cardName: r.cardName, collectionName: r.collectionName, binderName: r.binderName, finish: r.finishRaw,
                  condition: r.condition, quantityDelta: r.quantityDelta, collectionEntryID: r.collectionEntryID,
                  undoesActionID: r.undoesActionID, setCode: r.setCode, setName: r.setName, collectorNumber: r.collectorNumber,
                  rarity: r.rarity, language: r.language, purchasePrice: r.purchasePrice,
                  purchasePriceCurrency: r.purchasePriceCurrency, manaBoxID: r.manaBoxID, addedDate: r.addedDate,
                  sourceCollectionName: r.sourceCollectionName, collectionKind: r.collectionKindRaw)
    }

    func model() -> AuditRecord {
        let r = AuditRecord(id: id, actionID: actionID, action: AuditAction(rawValue: action) ?? .manualAdd, timestamp: timestamp,
                            scryfallID: scryfallID, cardName: cardName, collectionName: collectionName, binderName: binderName,
                            finish: CardFinish(rawValue: finish) ?? .normal, condition: condition, quantityDelta: quantityDelta,
                            collectionEntryID: collectionEntryID, undoesActionID: undoesActionID)
        r.actionRaw = action
        r.finishRaw = finish
        r.setCode = setCode; r.setName = setName; r.collectorNumber = collectorNumber; r.rarity = rarity
        r.language = language; r.purchasePrice = purchasePrice; r.purchasePriceCurrency = purchasePriceCurrency
        r.manaBoxID = manaBoxID; r.addedDate = addedDate; r.sourceCollectionName = sourceCollectionName
        r.collectionKindRaw = collectionKind
        return r
    }
}

nonisolated extension AppBackup.SavedSearchRecord {
    init(_ s: SavedSearch) {
        self.init(id: s.id, name: s.name, query: s.queryData, createdDate: s.createdDate, lastUsedDate: s.lastUsedDate, sortOrder: s.sortOrder)
    }

    func model() -> SavedSearch {
        let s = SavedSearch(id: id, name: name, query: CardSearchQuery(), sortOrder: sortOrder, createdDate: createdDate)
        s.queryData = query
        s.lastUsedDate = lastUsedDate
        return s
    }
}

// MARK: - The archive

nonisolated extension AppBackup {
    /// The files inside a backup zip.
    enum File: String, CaseIterable {
        case collections = "collections.json"
        case entries = "cards.json"
        case decks = "decks.json"
        case deckCards = "deck-cards.json"
        case folders = "deck-folders.json"
        case audit = "history.json"
        case branchNames = "history-branches.json"
        case savedSearches = "saved-searches.json"
        case settings = "settings.json"
    }

    static let csvName = "collection-manabox.csv"

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        // Exact: History orders actions by timestamp, and two made in the
        // same second must keep their order through a round trip.
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }

    func zipped() throws -> Data {
        var zip = ZipWriter(date: manifest.createdAt)
        let e = Self.encoder
        zip.add(BackupManifest.fileName, try e.encode(manifest))
        zip.add(File.collections.rawValue, try e.encode(collections))
        zip.add(File.entries.rawValue, try e.encode(entries))
        zip.add(File.decks.rawValue, try e.encode(decks))
        zip.add(File.deckCards.rawValue, try e.encode(deckCards))
        zip.add(File.folders.rawValue, try e.encode(folders))
        zip.add(File.audit.rawValue, try e.encode(audit))
        zip.add(File.branchNames.rawValue, try e.encode(branchNames))
        zip.add(File.savedSearches.rawValue, try e.encode(savedSearches))
        zip.add(File.settings.rawValue, try e.encode(settings))
        zip.add(Self.csvName, Data(Self.manaBoxCSV(entries).utf8))
        return zip.finish()
    }

    enum ReadError: Error, LocalizedError {
        case newerFormat(Int)
        var errorDescription: String? {
            switch self {
            case .newerFormat: return "This backup was made by a newer version of Magic Hat. Update the app to restore it."
            }
        }
    }

    /// Reads a backup zip. A file other than the manifest that is missing
    /// reads as empty, so a backup from before a table existed restores.
    static func read(_ data: Data) throws -> AppBackup {
        let zip = try ZipReader(data)
        let d = decoder
        let manifest = try d.decode(BackupManifest.self, from: zip.data(for: BackupManifest.fileName))
        guard manifest.format <= BackupManifest.currentFormat else { throw ReadError.newerFormat(manifest.format) }
        func table<T: Decodable>(_ file: File, _ type: T.Type, empty: T) throws -> T {
            guard zip.entry(named: file.rawValue) != nil else { return empty }
            return try d.decode(T.self, from: zip.data(for: file.rawValue))
        }
        return AppBackup(
            manifest: manifest,
            collections: try table(.collections, [CollectionRecord].self, empty: []),
            entries: try table(.entries, [EntryRecord].self, empty: []),
            decks: try table(.decks, [DeckRecord].self, empty: []),
            deckCards: try table(.deckCards, [DeckCardRecord].self, empty: []),
            folders: try table(.folders, [FolderRecord].self, empty: []),
            audit: try table(.audit, [AuditRecordValue].self, empty: []),
            branchNames: try table(.branchNames, [BranchNameRecord].self, empty: []),
            savedSearches: try table(.savedSearches, [SavedSearchRecord].self, empty: []),
            settings: try table(.settings, [String: String].self, empty: [:])
        )
    }

    /// The collection in ManaBox's export columns, which CSVParser (and
    /// ManaBox) read back. Deck rows are listed under their deck's key, as
    /// the binder name, so nothing is lost; lists are included too.
    static func manaBoxCSV(_ entries: [EntryRecord]) -> String {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency,Added"]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for e in entries.sorted(by: { ($0.collectionName, $0.name) < ($1.collectionName, $1.name) }) {
            let row: [String] = [
                e.collectionName, "binder", e.name, e.setCode, e.setName, e.collectorNumber, e.finish, e.rarity,
                String(e.quantity), e.manaBoxID ?? "", e.scryfallID, e.purchasePrice.map { String(format: "%.2f", $0) } ?? "",
                "false", "false", e.condition, e.language, e.purchasePriceCurrency ?? "", e.addedDate.map(iso.string(from:)) ?? "",
            ]
            lines.append(row.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
