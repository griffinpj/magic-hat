//
//  AuditRecord.swift
//  magic-hat
//
//  Append-only ledger of every card added to or removed from a collection
//  or a deck. Records sharing an `actionID` were produced by one user
//  action (e.g. a single import), which is what History lists and what
//  undo and redo work in.
//
//  Undo and redo never rewrite the ledger. Each is an action of its own —
//  `.undo` / `.redo`, every record carrying the negated (or re-applied)
//  delta and `undoesActionID` naming the user action it reverses — so the
//  ledger stays a true account of what happened to the copies, and the
//  timeline (what is applied, what can be redone, what an undo left behind
//  when a new action followed it) is derived from it: see HistoryTimeline.
//
//  A record also snapshots the row it touched (`EntrySnapshot`): the fields
//  the ledger's identity (card, collection, finish, condition, delta) does
//  not carry but a row needs when an undo has to bring it back — language,
//  the price paid, the set and number, and for a deck's row the collection
//  it was built from. Older records without one are rebuilt from CardMeta.
//

import Foundation
import SwiftData

nonisolated enum AuditAction: String, Codable, Sendable, CaseIterable {
    case importAdd      // rows created/increased by an import
    case importReplace  // rows removed because a binder was replaced
    case manualAdd
    case manualRemove
    /// Copies moved from a collection into a deck (pairs of −n / +n).
    case deckBuild
    /// Copies moved from a deck back to a collection.
    case deckDisassemble
    /// A user action reversed; `undoesActionID` names it.
    case undo
    /// An undone action applied again; `undoesActionID` names it.
    case redo

    /// Undo and redo are the timeline's mechanics, not entries in it.
    var isUserAction: Bool { self != .undo && self != .redo }
}

/// What a ledger record remembers about the row it changed, beyond the
/// row's identity, so the row can be recreated faithfully.
nonisolated struct EntrySnapshot: Hashable, Sendable {
    var setCode: String
    var setName: String
    var collectorNumber: String
    var rarity: String
    var language: String
    var purchasePrice: Double?
    var purchasePriceCurrency: String?
    var manaBoxID: String?
    var addedDate: Date?
    var sourceCollectionName: String?

    init(_ entry: CollectionEntry) {
        setCode = entry.setCode
        setName = entry.setName
        collectorNumber = entry.collectorNumber
        rarity = entry.rarity
        language = entry.language
        purchasePrice = entry.purchasePrice
        purchasePriceCurrency = entry.purchasePriceCurrency
        manaBoxID = entry.manaBoxID
        addedDate = entry.addedDate
        sourceCollectionName = entry.sourceCollectionName
    }
}

@Model
nonisolated final class AuditRecord {
    @Attribute(.unique) var id: UUID

    /// Groups all records emitted by one user action.
    var actionID: UUID
    #Index<AuditRecord>([\.actionID])

    var actionRaw: String
    var timestamp: Date

    // Snapshot of what changed (kept even if the entry is later deleted).
    var scryfallID: String
    var cardName: String
    /// The collection the copies moved in or out of: a collection's name,
    /// or a deck's hidden collection key ("deck:<uuid>"; History shows the
    /// deck's name). Records written before decks had keys here carry the
    /// display label "Deck: Name" instead, and those cannot be undone.
    var collectionName: String = "My Collection"
    /// Source binder from the import file. Historical only: binders are no
    /// longer part of the collection model, but older records name them and
    /// an append-only ledger does not rewrite its past. New records leave it
    /// empty.
    var binderName: String
    var finishRaw: String
    var condition: String

    /// Signed change in copies: positive = added, negative = removed.
    var quantityDelta: Int

    /// Back-reference to the affected CollectionEntry (nil if it was deleted).
    var collectionEntryID: UUID?

    /// For an `.undo` or `.redo` record: the user action it reverses or
    /// re-applies.
    var undoesActionID: UUID?

    // The row's snapshot (EntrySnapshot), each optional so records written
    // before it existed decode unchanged.
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

    var action: AuditAction {
        get { AuditAction(rawValue: actionRaw) ?? .manualAdd }
        set { actionRaw = newValue.rawValue }
    }

    var finish: CardFinish { CardFinish(rawValue: finishRaw) ?? .normal }

    /// The snapshot, when the record carries one.
    var snapshot: EntrySnapshot? {
        get {
            guard let setCode, let setName, let collectorNumber, let rarity, let language else { return nil }
            var s = EntrySnapshot(setCode: setCode, setName: setName, collectorNumber: collectorNumber,
                                  rarity: rarity, language: language)
            s.purchasePrice = purchasePrice
            s.purchasePriceCurrency = purchasePriceCurrency
            s.manaBoxID = manaBoxID
            s.addedDate = addedDate
            s.sourceCollectionName = sourceCollectionName
            return s
        }
        set {
            setCode = newValue?.setCode
            setName = newValue?.setName
            collectorNumber = newValue?.collectorNumber
            rarity = newValue?.rarity
            language = newValue?.language
            purchasePrice = newValue?.purchasePrice
            purchasePriceCurrency = newValue?.purchasePriceCurrency
            manaBoxID = newValue?.manaBoxID
            addedDate = newValue?.addedDate
            sourceCollectionName = newValue?.sourceCollectionName
        }
    }

    init(
        id: UUID = UUID(),
        actionID: UUID,
        action: AuditAction,
        timestamp: Date = Date(),
        scryfallID: String,
        cardName: String,
        collectionName: String,
        binderName: String = "",
        finish: CardFinish,
        condition: String,
        quantityDelta: Int,
        collectionEntryID: UUID?,
        undoesActionID: UUID? = nil,
        snapshot: EntrySnapshot? = nil
    ) {
        self.id = id
        self.actionID = actionID
        self.actionRaw = action.rawValue
        self.timestamp = timestamp
        self.scryfallID = scryfallID
        self.cardName = cardName
        self.collectionName = collectionName
        self.binderName = binderName
        self.finishRaw = finish.rawValue
        self.condition = condition
        self.quantityDelta = quantityDelta
        self.collectionEntryID = collectionEntryID
        self.undoesActionID = undoesActionID
        self.snapshot = snapshot
    }
}

nonisolated extension EntrySnapshot {
    init(setCode: String, setName: String, collectorNumber: String, rarity: String, language: String) {
        self.setCode = setCode
        self.setName = setName
        self.collectorNumber = collectorNumber
        self.rarity = rarity
        self.language = language
    }
}
