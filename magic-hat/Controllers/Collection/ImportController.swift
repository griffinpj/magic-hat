//
//  ImportController.swift
//  magic-hat
//
//  Applies a parsed ManaBox import into the SwiftData store. Runs on its own
//  background ModelContext (@ModelActor) so inserting thousands of records
//  never blocks the main thread, and reports fractional progress so the UI
//  can show a loading bar. Every change is recorded in the append-only
//  AuditRecord ledger under a single actionID for grouping and future
//  undo/redo.
//
//  This project uses default MainActor isolation, so SwiftData models live on
//  the main actor. Rather than fight that with a background context, the
//  import runs on the main context but yields to the run loop between chunks
//  so the UI stays responsive and the progress bar animates smoothly.
//

import Foundation
import SwiftData

enum ImportMode: Sendable {
    case add        // merge/upsert into existing binders
    case replace    // clear selected binders first, then insert
}

@MainActor
enum ImportController {
    struct Summary: Sendable {
        let actionID: UUID
        let added: Int      // total copies added
        let removed: Int    // total copies removed (replace mode)
        let binders: [String]
    }

    /// Imports `rows` limited to `selectedBinders` using `mode`, reporting
    /// progress in [0, 1] as records are written. Yields between chunks so
    /// the main thread never stalls on a large import.
    static func apply(
        rows: [ManaBoxRow],
        selectedBinders: Set<String>,
        mode: ImportMode,
        context modelContext: ModelContext,
        progress: (Double) -> Void
    ) async throws -> Summary {
        let actionID = UUID()
        let now = Date()
        var addedCount = 0
        var removedCount = 0

        let relevant = rows.filter { selectedBinders.contains($0.binderName) && $0.quantity > 0 }
        let total = max(relevant.count, 1)

        progress(0)

        // 1. Replace mode: clear existing entries in the target binders and
        //    log a removal for each copy.
        if mode == .replace {
            for binder in selectedBinders {
                let descriptor = FetchDescriptor<CollectionEntry>(
                    predicate: #Predicate { $0.binderName == binder }
                )
                let existing = try modelContext.fetch(descriptor)
                for entry in existing {
                    removedCount += entry.quantity
                    modelContext.insert(AuditRecord(
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
                    modelContext.delete(entry)
                }
            }
        }

        // 2. Build a lookup of surviving entries for upsert (add mode).
        var existingByKey: [String: CollectionEntry] = [:]
        if mode == .add {
            let all = try modelContext.fetch(FetchDescriptor<CollectionEntry>())
            for entry in all where selectedBinders.contains(entry.binderName) {
                existingByKey[entry.mergeKey] = entry
            }
        }

        // 3. Ensure a CardMeta placeholder exists per Scryfall ID (hydrated
        //    lazily later). Track which we've seen to avoid dup inserts.
        var knownMeta = Set(
            try modelContext.fetch(FetchDescriptor<CardMeta>()).map(\.scryfallID)
        )

        // 4. Insert/upsert rows, reporting progress and saving in batches so
        //    memory stays bounded for very large imports. Progress updates
        //    more often than saves so the bar animates smoothly.
        let saveEvery = 500
        let reportEvery = max(total / 100, 1)
        var processed = 0

        for row in relevant {
            if !knownMeta.contains(row.scryfallID) {
                modelContext.insert(CardMeta(
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
                modelContext.insert(entry)
                if mode == .add { existingByKey[key] = entry }
            }

            addedCount += row.quantity
            modelContext.insert(AuditRecord(
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

            processed += 1
            if processed % saveEvery == 0 {
                try modelContext.save()
                // Let the run loop breathe: UI updates and stays responsive.
                await Task.yield()
            }
            if processed % reportEvery == 0 {
                progress(Double(processed) / Double(total))
            }
        }

        try modelContext.save()
        progress(1)

        return Summary(
            actionID: actionID,
            added: addedCount,
            removed: removedCount,
            binders: Array(selectedBinders).sorted()
        )
    }
}
