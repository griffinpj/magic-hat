//
//  LedgerReplay.swift
//  magic-hat
//
//  Undo and redo, as a replay of the ledger: reversing a user action means
//  applying each of its records with the opposite sign to the row it names
//  (card + collection + finish + condition, the merge key everything else
//  uses), re-applying means the original sign. Every replay is itself a
//  new ledger action (`.undo` / `.redo`, `undoesActionID` set), so the
//  ledger stays append-only and its sum is always the collection.
//
//  Rows that come back are rebuilt from the record's snapshot (language,
//  price paid, set and number, a deck row's source collection), falling
//  back to CardMeta for the printing's details when an older record has
//  none. A collection that was deleted comes back with its rows. A deck
//  that no longer exists does not: copies moved into or out of it can't be
//  replayed, and the replay refuses rather than filing rows under a deck
//  nobody can open. The same for records written before deck rows were
//  keyed ("Deck: Name" labels).
//
//  All-or-nothing per action: the requirements (enough copies in every
//  row a replay removes from) are checked before anything changes.
//  Runs on whatever context it is given — CardMetaWriter's, in the app.
//

import Foundation
import SwiftData

nonisolated enum LedgerReplay {
    enum Direction: Sendable {
        case undo, redo

        var factor: Int { self == .undo ? -1 : 1 }
        var action: AuditAction { self == .undo ? .undo : .redo }
    }

    enum ReplayError: Error, LocalizedError, Equatable {
        case nothingToReplay
        case legacyDeckRecord
        case deckMissing
        case copiesMissing(String)

        var errorDescription: String? {
            switch self {
            case .nothingToReplay: return "There is nothing to undo."
            case .legacyDeckRecord: return "This deck action was recorded before undo existed and can't be reversed."
            case .deckMissing: return "That deck no longer exists, so its cards can't be moved."
            case .copiesMissing(let name): return "\(name) is no longer in the collection to take back."
            }
        }
    }

    /// Reverses (undo) or re-applies (redo) the user action `actionID`,
    /// writing the replay as a new action. Returns the new action's id.
    @discardableResult
    static func replay(actionID: UUID, direction: Direction, in context: ModelContext) throws -> UUID {
        let records = try context.fetch(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.actionID == actionID }))
        guard !records.isEmpty else { throw ReplayError.nothingToReplay }

        // 1. Every collection the replay touches must be addressable.
        let collectionNames = Set(records.map(\.collectionName))
        if collectionNames.contains(where: { $0.hasPrefix("Deck: ") }) { throw ReplayError.legacyDeckRecord }
        let deckIDs = collectionNames.compactMap(Deck.deckID(fromCollectionKey:))
        if !deckIDs.isEmpty {
            let decks = try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { deckIDs.contains($0.id) }))
            guard decks.count == Set(deckIDs).count else { throw ReplayError.deckMissing }
        }

        // 2. The rows as they stand, by merge key.
        let ids = Array(Set(records.map(\.scryfallID)))
        var rows: [String: CollectionEntry] = [:]
        var metas: [String: CardMeta] = [:]
        for chunk in ids.chunked(into: 500) {
            for entry in try context.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                rows[entry.mergeKey] = entry
            }
            for meta in try context.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })) {
                metas[meta.scryfallID] = meta
            }
        }

        // 3. Check before changing: every row the replay takes copies from
        //    must still have them.
        var net: [String: Int] = [:]
        for record in records { net[key(of: record), default: 0] += direction.factor * record.quantityDelta }
        for record in records {
            let k = key(of: record)
            if (rows[k]?.quantity ?? 0) + (net[k] ?? 0) < 0 { throw ReplayError.copiesMissing(record.cardName) }
        }

        // 4. Collections that were deleted come back with their rows.
        let plainNames = collectionNames.filter { !Deck.isDeckCollection($0) }
        if !plainNames.isEmpty {
            let existing = Set(try context.fetch(FetchDescriptor<MTGCollection>()).map(\.name))
            for name in plainNames.subtracting(existing) { context.insert(MTGCollection(name: name)) }
        }

        // 5. Apply, recording each change under the new action.
        let newID = UUID()
        let now = Date()
        var written = 0
        for record in records {
            let delta = direction.factor * record.quantityDelta
            guard delta != 0 else { continue }
            let k = key(of: record)
            let row: CollectionEntry
            if let existing = rows[k] {
                existing.quantity += delta
                row = existing
            } else {
                let created = make(from: record, quantity: delta, meta: metas[record.scryfallID], now: now)
                context.insert(created)
                rows[k] = created
                row = created
            }
            context.insert(AuditRecord(
                actionID: newID, action: direction.action, timestamp: now,
                scryfallID: record.scryfallID, cardName: record.cardName, collectionName: record.collectionName,
                finish: record.finish, condition: record.condition, quantityDelta: delta,
                collectionEntryID: row.id, undoesActionID: actionID, snapshot: EntrySnapshot(row)
            ))
            if row.quantity <= 0 {
                context.delete(row)
                rows[k] = nil
            }
            written += 1
            if written % 500 == 0 { try context.save() }
        }
        try context.save()
        return newID
    }

    private static func key(of record: AuditRecord) -> String {
        CollectionEntry.mergeKey(scryfallID: record.scryfallID, collectionName: record.collectionName,
                                 finish: record.finishRaw, condition: record.condition)
    }

    /// A row brought back: the record's snapshot where it has one, the
    /// catalog's details for the printing where it doesn't.
    private static func make(from record: AuditRecord, quantity: Int, meta: CardMeta?, now: Date) -> CollectionEntry {
        let snapshot = record.snapshot
        let entry = CollectionEntry(
            scryfallID: record.scryfallID,
            collectionName: record.collectionName,
            name: record.cardName.isEmpty ? (meta?.name ?? "") : record.cardName,
            setCode: snapshot?.setCode ?? meta?.setCode ?? "",
            setName: snapshot?.setName ?? meta?.setName ?? "",
            collectorNumber: snapshot?.collectorNumber ?? meta?.collectorNumber ?? "",
            rarity: snapshot?.rarity ?? meta?.rarity ?? "",
            finish: record.finish,
            quantity: quantity,
            condition: record.condition,
            language: snapshot?.language ?? "en",
            purchasePrice: snapshot?.purchasePrice,
            purchasePriceCurrency: snapshot?.purchasePriceCurrency,
            manaBoxID: snapshot?.manaBoxID,
            addedDate: snapshot?.addedDate ?? now
        )
        entry.sourceCollectionName = snapshot?.sourceCollectionName
        entry.card = meta
        return entry
    }
}
