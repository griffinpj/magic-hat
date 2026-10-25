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
        case deckStillBuilt(String)
        case deckRecordUnreadable
        /// The step was offered against a timeline that has since moved —
        /// History read the ledger, then something else wrote to it.
        case timelineMoved

        var errorDescription: String? {
            switch self {
            case .nothingToReplay: return "There is nothing to undo."
            case .timelineMoved: return "History changed since this was shown. Nothing was changed; try again."
            case .legacyDeckRecord: return "This deck action was recorded before undo existed and can't be reversed."
            case .deckMissing: return "That deck no longer exists, so its cards can't be moved."
            case .copiesMissing(let name): return "\(name) is no longer in the collection to take back."
            case .deckStillBuilt(let name): return "\(name) is built. Disassemble it before deleting it."
            case .deckRecordUnreadable: return "This deck's record can't be read, so it can't be brought back."
            }
        }
    }

    /// Why `actionID` can't be replayed as things stand, or nil when it
    /// can: the checks `replay` makes before it changes anything, with no
    /// changes made. History asks before it offers Undo and Redo, so a
    /// step that would fail says so on its row instead of in an alert
    /// after the tap.
    static func blocker(actionID: UUID, direction: Direction, in context: ModelContext) -> ReplayError? {
        do {
            let records = try context.fetch(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.actionID == actionID }))
            if let deckRecord = records.first(where: \.isDeckRecord) {
                _ = try checkDeckRecord(deckRecord, direction: direction, in: context)
            } else {
                _ = try check(records, direction: direction, in: context, withMetas: false)
            }
            return nil
        } catch let error as ReplayError {
            return error
        } catch {
            return nil      // a fetch failed: let the replay itself report it
        }
    }

    /// Reverses (undo) or re-applies (redo) the user action `actionID`,
    /// writing the replay as a new action. Returns the new action's id.
    ///
    /// The step is checked against the ledger as it stands on this
    /// context, not the timeline the caller was shown: Undo is offered
    /// from History's last read, and a write since (another tab, a sync)
    /// moves the head. Undoing an action that is no longer the head wrote
    /// negated deltas the timeline then ignored as a stray record — the
    /// copies gone and History still saying Applied.
    @discardableResult
    static func replay(actionID: UUID, direction: Direction, in context: ModelContext) throws -> UUID {
        var head = Head(try timeline(in: context))
        return try replay(actionID: actionID, direction: direction, in: context, head: &head)
    }

    /// Several steps in order (Undo Through Here, a Switch), checked against
    /// one read of the ledger: `head` moves as each lands. Reading the whole
    /// ledger per step was ~90ms a step on the real export's — forty back
    /// was seconds, with every write queued behind it on the writer.
    /// Returns how many steps landed; a refusal or failure throws after the
    /// ones before it were saved, as a step at a time did.
    @discardableResult
    static func replay(_ steps: [(actionID: UUID, direction: Direction)], in context: ModelContext,
                       landed: (Int) -> Void = { _ in }) throws -> Int {
        guard !steps.isEmpty else { return 0 }
        var head = Head(try timeline(in: context))
        var done = 0
        for step in steps {
            try replay(actionID: step.actionID, direction: step.direction, in: context, head: &head)
            done += 1
            landed(done)
        }
        return done
    }

    /// Where the timeline's head stands for a run of steps: read from the
    /// ledger once, then moved by each step as it lands.
    struct Head {
        private(set) var id: UUID?
        private let parent: [UUID: UUID?]

        init(_ timeline: HistoryTimeline) {
            id = timeline.head
            parent = timeline.parent
        }

        /// Undo takes only the head; redo only one of its children.
        func allows(_ actionID: UUID, _ direction: Direction) -> Bool {
            switch direction {
            case .undo: return id == actionID
            case .redo: return parent[actionID] == .some(id)
            }
        }

        mutating func step(_ actionID: UUID, _ direction: Direction) {
            id = direction == .undo ? (parent[actionID] ?? nil) : actionID
        }
    }

    @discardableResult
    private static func replay(actionID: UUID, direction: Direction, in context: ModelContext,
                               head: inout Head) throws -> UUID {
        guard head.allows(actionID, direction) else { throw ReplayError.timelineMoved }
        let newID = try apply(actionID: actionID, direction: direction, in: context)
        head.step(actionID, direction)
        return newID
    }

    private static func apply(actionID: UUID, direction: Direction, in context: ModelContext) throws -> UUID {
        let records = try context.fetch(FetchDescriptor<AuditRecord>(predicate: #Predicate { $0.actionID == actionID }))
        if let deckRecord = records.first(where: \.isDeckRecord) {
            return try replayDeckRecord(deckRecord, direction: direction, in: context)
        }
        let checked = try check(records, direction: direction, in: context)
        var rows = checked.rows
        let metas = checked.metas
        let collectionNames = Set(records.map(\.collectionName))

        // 4. Collections that were deleted come back with their rows — a
        //    list as a list.
        let plainNames = collectionNames.filter { !Deck.isDeckCollection($0) }
        if !plainNames.isEmpty {
            let existing = Set(try context.fetch(FetchDescriptor<MTGCollection>()).map(\.name))
            let lists = Set(records.filter { $0.collectionKindRaw == CollectionKind.list.rawValue }.map(\.collectionName))
            for name in plainNames.subtracting(existing) {
                context.insert(MTGCollection(name: name, kind: lists.contains(name) ? .list : .collection))
            }
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
                collectionEntryID: row.id, undoesActionID: actionID, snapshot: EntrySnapshot(row),
                collectionKind: record.collectionKindRaw == CollectionKind.list.rawValue ? .list : nil
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

    /// The timeline as the ledger on `context` has it now — the same steps
    /// `CollectionStore.history()` resolves (one per action, at its
    /// earliest record), without the rest of the log.
    static func timeline(in context: ModelContext) throws -> HistoryTimeline {
        var descriptor = FetchDescriptor<AuditRecord>()
        descriptor.propertiesToFetch = [\.actionID, \.timestamp, \.actionRaw, \.undoesActionID]
        var steps: [UUID: HistoryStep] = [:]
        for record in try context.fetch(descriptor) {
            if let seen = steps[record.actionID], seen.timestamp <= record.timestamp { continue }
            steps[record.actionID] = HistoryStep(id: record.actionID, kind: record.action,
                                                 target: record.undoesActionID, timestamp: record.timestamp)
        }
        return HistoryTimeline.resolve(Array(steps.values))
    }

    // MARK: A deck created or deleted

    /// Whether replaying a deck record takes the deck away — undoing its
    /// creation, redoing its deletion — or brings it back.
    static func removesDeck(_ action: AuditAction, _ direction: Direction) -> Bool {
        (action == .deckDelete) == (direction == .redo)
    }

    /// What must hold to bring a deck back (its record readable) or to take
    /// it away (nothing built in it). Returns the deck as recorded and,
    /// when it exists now, the deck itself.
    private static func checkDeckRecord(_ record: AuditRecord, direction: Direction,
                                        in context: ModelContext) throws -> (saved: DeletedDeck, live: Deck?) {
        guard let data = record.payload, let saved = try? DeletedDeck.decode(data) else { throw ReplayError.deckRecordUnreadable }
        let id = saved.deck.id
        let live = try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
        if removesDeck(record.action, direction), live != nil {
            let key = Deck.collectionKey(for: id)
            let built = try context.fetchCount(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == key }))
            if built > 0 { throw ReplayError.deckStillBuilt(saved.deck.name) }
        }
        return (saved, live)
    }

    /// Bringing a deck back puts it as it was recorded — the same id, so
    /// every record History holds against it names a deck that exists
    /// again; taking it away records it afresh first (it may have changed
    /// since — a list filled after it was created), so coming back brings
    /// that. The replay is one zero-delta record, which is what the
    /// timeline moves its head by.
    private static func replayDeckRecord(_ record: AuditRecord, direction: Direction, in context: ModelContext) throws -> UUID {
        let (saved, live) = try checkDeckRecord(record, direction: direction, in: context)
        if removesDeck(record.action, direction) {
            if let live {
                record.payload = try DeletedDeck(live, in: context).encoded()
                try DeckEditController.remove(live, in: context)
            }
        } else if live == nil {
            try saved.restore(in: context)
        }
        let newID = UUID()
        context.insert(AuditRecord(actionID: newID, action: direction.action, scryfallID: "", cardName: record.cardName,
                                   collectionName: record.collectionName, finish: .normal, condition: "", quantityDelta: 0,
                                   collectionEntryID: nil, undoesActionID: record.actionID))
        try context.save()
        return newID
    }

    /// Steps 1–3: everything that must hold before a replay changes a row.
    /// Returns the rows as they stand (by merge key) and the cards' metadata.
    /// `withMetas: false` for a check alone: the metadata is only for rows
    /// a replay has to make, and fetching it for an import's thousands of
    /// cards on every look at History was the cost of the check.
    private static func check(_ records: [AuditRecord], direction: Direction, in context: ModelContext,
                              withMetas: Bool = true) throws -> (rows: [String: CollectionEntry], metas: [String: CardMeta]) {
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
            guard withMetas else { continue }
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

        return (rows, metas)
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
