//
//  BackupController.swift
//  magic-hat
//
//  Backing up and restoring everything the user has entered (AppBackup).
//  The reads and writes run on CardMetaWriter's background context — a
//  backup of the real collection is thousands of rows and ledger records,
//  and a restore replaces all of them — and the JSON and zip work runs in
//  detached tasks, so neither touches the main thread.
//
//  Restore replaces, it doesn't merge: a backup is a point in time, and
//  merging two ledgers would make History's account of the copies wrong.
//  Before replacing anything the current state is saved as a backup of
//  its own ("Before Restore …"), so a restore can itself be undone by
//  restoring that file. The card catalog is left alone; restored rows link
//  to the CardMeta already on the phone, and any it lacks are pending
//  until hydration fetches them.
//

import Foundation
import SwiftData

nonisolated enum BackupController {
    /// UserDefaults keys that travel with a backup.
    static let settingsKeys = [
        AppSettings.currencyKey, AppSettings.cardLanguageKey, AppSettings.gridColumnsKey,
        "collection.sort", "deck.sort", "decks.layout", "decks.sort", AddTarget.lastKey,
    ]

    static func currentSettings() -> [String: String] {
        var out: [String: String] = [:]
        for key in settingsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { out[key] = "\(value)" }
        }
        return out
    }

    static func apply(settings: [String: String]) {
        for (key, value) in settings where settingsKeys.contains(key) {
            if key == AppSettings.gridColumnsKey, let n = Int(value) {
                UserDefaults.standard.set(n, forKey: key)
            } else {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    /// Everything on `context`, as records.
    static func snapshot(in context: ModelContext, settings: [String: String], appVersion: String, now: Date = Date()) throws -> AppBackup {
        let collections = try context.fetch(FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)])).map(AppBackup.CollectionRecord.init)
        let entries = try context.fetch(FetchDescriptor<CollectionEntry>()).map(AppBackup.EntryRecord.init)
        let deckModels = try context.fetch(FetchDescriptor<Deck>())
        let decks = deckModels.map(AppBackup.DeckRecord.init)
        let deckCards = try context.fetch(FetchDescriptor<DeckCard>()).compactMap(AppBackup.DeckCardRecord.init)
        let folders = try context.fetch(FetchDescriptor<DeckFolder>()).map {
            AppBackup.FolderRecord(id: $0.id, name: $0.name, parentID: $0.parentID, createdDate: $0.createdDate)
        }
        let audit = try context.fetch(FetchDescriptor<AuditRecord>(sortBy: [SortDescriptor(\.timestamp)])).map(AppBackup.AuditRecordValue.init)
        let names = try context.fetch(FetchDescriptor<HistoryBranchName>()).map { AppBackup.BranchNameRecord(actionID: $0.actionID, name: $0.name) }
        let searches = try context.fetch(FetchDescriptor<SavedSearch>(sortBy: [SortDescriptor(\.sortOrder)])).map(AppBackup.SavedSearchRecord.init)
        let manifest = BackupManifest(format: BackupManifest.currentFormat, createdAt: now, appVersion: appVersion,
                                      collections: collections.count, entries: entries.count,
                                      copies: entries.reduce(0) { $0 + $1.quantity }, decks: decks.count,
                                      historyRecords: audit.count)
        return AppBackup(manifest: manifest, collections: collections, entries: entries, decks: decks, deckCards: deckCards,
                         folders: folders, audit: audit, branchNames: names, savedSearches: searches, settings: settings)
    }

    /// Replaces every user table on `context` with `backup`.
    static func restore(_ backup: AppBackup, in context: ModelContext) throws {
        try context.delete(model: CollectionEntry.self)
        try context.delete(model: DeckCard.self)
        try context.delete(model: Deck.self)
        try context.delete(model: DeckFolder.self)
        try context.delete(model: MTGCollection.self)
        try context.delete(model: AuditRecord.self)
        try context.delete(model: HistoryBranchName.self)
        try context.delete(model: SavedSearch.self)
        try context.save()

        for c in backup.collections {
            context.insert(MTGCollection(id: c.id, name: c.name, createdDate: c.createdDate,
                                         kind: c.kind.flatMap(CollectionKind.init(rawValue:)) ?? .collection))
        }
        // Rows link to the catalog's metadata where the phone has it.
        let ids = Array(Set(backup.entries.map(\.scryfallID)))
        var metas: [String: CardMeta] = [:]
        for chunk in ids.chunked(into: 500) {
            for meta in try context.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                metas[meta.scryfallID] = meta
            }
        }
        for (i, record) in backup.entries.enumerated() {
            let entry = record.model()
            entry.card = metas[record.scryfallID]
            context.insert(entry)
            if i % 1000 == 999 { try context.save() }
        }
        for f in backup.folders {
            context.insert(DeckFolder(id: f.id, name: f.name, parentID: f.parentID, createdDate: f.createdDate))
        }
        var decks: [UUID: Deck] = [:]
        for d in backup.decks {
            let deck = d.model()
            context.insert(deck)
            decks[d.id] = deck
        }
        for c in backup.deckCards {
            guard let deck = decks[c.deckID] else { continue }
            let card = DeckCard(id: c.id, scryfallID: c.scryfallID, oracleID: c.oracleID, name: c.name,
                                board: DeckBoard(rawValue: c.board) ?? .main, quantity: c.quantity, addedDate: c.addedDate)
            card.deck = deck
            context.insert(card)
        }
        for (i, r) in backup.audit.enumerated() {
            context.insert(r.model())
            if i % 1000 == 999 { try context.save() }
        }
        for n in backup.branchNames { context.insert(HistoryBranchName(actionID: n.actionID, name: n.name)) }
        for s in backup.savedSearches { context.insert(s.model()) }
        try context.save()
    }
}

// MARK: - Files

/// Where backups live on the phone: Documents/Backups, which the Files app
/// shows under On My iPhone › Magic Hat. Automatic backups also go to the
/// folder the user picked (BackupScheduler).
nonisolated enum BackupFiles {
    static var localFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// "Magic Hat Backup 2026-09-27 1030.zip".
    static func fileName(for date: Date, prefix: String = "Magic Hat Backup") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        return "\(prefix) \(f.string(from: date)).zip"
    }

    /// Backups in `folder`, newest first.
    static func backups(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "zip" && $0.lastPathComponent.hasPrefix("Magic Hat") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da > db
            }
    }

    /// Keeps the newest `keep` automatic backups in `folder`.
    static func prune(_ folder: URL, keep: Int) {
        let automatic = backups(in: folder).filter { $0.lastPathComponent.hasPrefix("Magic Hat Backup") }
        for url in automatic.dropFirst(keep) { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: - Running it

extension BackupController {
    /// Builds a backup and writes it into `folder` (the local one by
    /// default). Returns the file.
    @MainActor
    static func makeBackup(container: ModelContainer, into folder: URL = BackupFiles.localFolder,
                           prefix: String = "Magic Hat Backup") async throws -> URL {
        let settings = currentSettings()
        let backup = try await CardMetaWriter.shared(for: container).runBackupSnapshot(settings: settings, appVersion: AboutInfo.version)
        let name = BackupFiles.fileName(for: backup.manifest.createdAt, prefix: prefix)
        return try await Task.detached(priority: .userInitiated) {
            let data = try backup.zipped()
            let url = folder.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            return url
        }.value
    }

    /// Reads a backup file (security-scoped if it came from the picker).
    static func read(_ url: URL) async throws -> AppBackup {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var coordinated: Data?
            var coordinationError: NSError?
            var readError: Error?
            // iCloud Drive files may need downloading; a coordinated read
            // waits for that.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { real in
                do { coordinated = try Data(contentsOf: real) } catch { readError = error }
            }
            if let coordinationError { throw coordinationError }
            if let readError { throw readError }
            return try AppBackup.read(coordinated ?? Data())
        }.value
    }

    /// Replaces everything with `backup`, after saving what is there now.
    @MainActor
    static func restore(_ backup: AppBackup, container: ModelContainer) async throws -> URL {
        let safety = try await makeBackup(container: container, prefix: "Magic Hat Before Restore")
        try await CardMetaWriter.shared(for: container).runRestore(backup)
        apply(settings: backup.settings)
        CollectionChangeTracker.shared.bump()
        DeckChangeTracker.shared.bump()
        return safety
    }
}
