//
//  AuditRecord.swift
//  magic-hat
//
//  Append-only ledger of every card added to or removed from the
//  collection. Records sharing an `actionID` were produced by one user
//  action (e.g. a single import), which lets us group them in History and
//  lays the groundwork for undo/redo later.
//

import Foundation
import SwiftData

enum AuditAction: String, Codable {
    case importAdd      // rows created/increased by an import
    case importReplace  // rows removed because a binder was replaced
    case manualAdd
    case manualRemove
}

@Model
final class AuditRecord {
    @Attribute(.unique) var id: UUID

    /// Groups all records emitted by one user action.
    var actionID: UUID

    var actionRaw: String
    var timestamp: Date

    // Snapshot of what changed (kept even if the entry is later deleted).
    var scryfallID: String
    var cardName: String
    var binderName: String
    var finishRaw: String
    var condition: String

    /// Signed change in copies: positive = added, negative = removed.
    var quantityDelta: Int

    /// Back-reference to the affected CollectionEntry (nil if it was deleted).
    var collectionEntryID: UUID?

    var action: AuditAction {
        get { AuditAction(rawValue: actionRaw) ?? .manualAdd }
        set { actionRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        actionID: UUID,
        action: AuditAction,
        timestamp: Date = Date(),
        scryfallID: String,
        cardName: String,
        binderName: String,
        finish: CardFinish,
        condition: String,
        quantityDelta: Int,
        collectionEntryID: UUID?
    ) {
        self.id = id
        self.actionID = actionID
        self.actionRaw = action.rawValue
        self.timestamp = timestamp
        self.scryfallID = scryfallID
        self.cardName = cardName
        self.binderName = binderName
        self.finishRaw = finish.rawValue
        self.condition = condition
        self.quantityDelta = quantityDelta
        self.collectionEntryID = collectionEntryID
    }
}
