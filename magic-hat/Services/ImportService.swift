//
//  ImportService.swift
//  magic-hat
//
//  Applies a parsed ManaBox import into the SwiftData store. Every change
//  is recorded in the append-only AuditRecord ledger under a single
//  actionID so History can group it and undo/redo can be added later.
//

import Foundation
import SwiftData

enum ImportMode {
    case add        // merge/upsert into existing binders
    case replace    // clear selected binders first, then insert
}

@MainActor
enum ImportService {
    struct Summary {
        let actionID: UUID
        let added: Int      // total copies added
        let removed: Int    // total copies removed (replace mode)
        let binders: [String]
    }

    /// Imports `rows` limited to `selectedBinders` using `mode`.
    /// Returns a summary of what changed.
    @discardableResult
    static func apply(
        rows: [ManaBoxRow],
        selectedBinders: Set<String>,
        mode: ImportMode,
        context: ModelContext
    ) throws -> Summary {
        let actionID = UUID()
        let now = Date()
        var addedCount = 0
        var removedCount = 0

        let relevant = rows.filter { selectedBinders.contains($0.binderName) }

        // 1. Replace mode: clear existing entries in the target binders and
        //    log a removal for each copy.
        if mode == .replace {
            for binder in selectedBinders {
                let descriptor = FetchDescriptor<CollectionEntry>(
                    predicate: #Predicate { $0.binderName == binder }
                )
                let existing = try context.fetch(descriptor)
                for entry in existing {
                    removedCount += entry.quantity
                    context.insert(AuditRecord(
                        actionID: actionID,
                        action: .importReplace,
                        timestamp: now,
                        scryfallID: entry.scryfallID,
                        cardName: entry.name,
                        binderName: entry.binderName,
                        finish: entry.finish,
                        condition: entry.condition,
                        quantityDelta: -entry.quantity,
                        collectionEntryID: entry.id
                    ))
                    context.delete(entry)
                }
            }
        }

        // 2. Build a lookup of surviving entries for upsert (add mode).
        var existingByKey: [String: CollectionEntry] = [:]
        if mode == .add {
            let all = try context.fetch(FetchDescriptor<CollectionEntry>())
            for entry in all where selectedBinders.contains(entry.binderName) {
                existingByKey[entry.mergeKey] = entry
            }
        }

        // 3. Ensure a CardMeta placeholder exists per Scryfall ID (hydrated
        //    lazily later). Track which we've seen to avoid dup inserts.
        var knownMeta = Set(
            try context.fetch(FetchDescriptor<CardMeta>()).map(\.scryfallID)
        )

        // 4. Insert/upsert rows.
        for row in relevant where row.quantity > 0 {
            if !knownMeta.contains(row.scryfallID) {
                context.insert(CardMeta(
                    scryfallID: row.scryfallID,
                    name: row.name,
                    setCode: row.setCode,
                    setName: row.setName,
                    collectorNumber: row.collectorNumber,
                    rarity: row.rarity
                ))
                knownMeta.insert(row.scryfallID)
            }

            let entry: CollectionEntry
            let key = "\(row.scryfallID)|\(row.binderName)|\(row.finish.rawValue)|\(row.condition)"
            if mode == .add, let existing = existingByKey[key] {
                existing.quantity += row.quantity
                entry = existing
            } else {
                entry = CollectionEntry(
                    scryfallID: row.scryfallID,
                    binderName: row.binderName,
                    binderType: row.binderType,
                    name: row.name,
                    setCode: row.setCode,
                    setName: row.setName,
                    collectorNumber: row.collectorNumber,
                    rarity: row.rarity,
                    finish: row.finish,
                    quantity: row.quantity,
                    condition: row.condition,
                    language: row.language,
                    purchasePrice: row.purchasePrice,
                    purchasePriceCurrency: row.purchasePriceCurrency,
                    manaBoxID: row.manaBoxID,
                    addedDate: row.added
                )
                context.insert(entry)
                if mode == .add { existingByKey[key] = entry }
            }

            addedCount += row.quantity
            context.insert(AuditRecord(
                actionID: actionID,
                action: .importAdd,
                timestamp: now,
                scryfallID: row.scryfallID,
                cardName: row.name,
                binderName: row.binderName,
                finish: row.finish,
                condition: row.condition,
                quantityDelta: row.quantity,
                collectionEntryID: entry.id
            ))
        }

        try context.save()

        return Summary(
            actionID: actionID,
            added: addedCount,
            removed: removedCount,
            binders: Array(selectedBinders).sorted()
        )
    }
}
