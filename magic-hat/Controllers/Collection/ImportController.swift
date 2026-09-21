//
//  ImportController.swift
//  magic-hat
//
//  Applies a parsed ManaBox import into the SwiftData store and reports
//  fractional progress for the wizard's bar. Every change is recorded in the
//  append-only AuditRecord ledger under a single actionID for grouping and
//  future undo/redo.
//
//  Writes run on the main context, chunked with Task.yield() between batches
//  so the run loop keeps animating. (Reads go through CollectionStore on a
//  background context; writes stay here so @Query-backed views see them
//  without a merge step.) When it finishes it bumps CollectionChangeTracker
//  so snapshot-backed views refetch.
//

import Foundation
import SwiftData

nonisolated enum ImportMode: Sendable {
    case add        // merge into the collection; matching rows sum quantities
    case replace    // clear the whole collection first, then insert
}

@MainActor
enum ImportController {
    struct Summary: Sendable {
        let actionID: UUID
        let added: Int      // total copies added
        let removed: Int    // total copies removed (replace mode)
        let collectionName: String
        /// Which binders in the file were chosen. Informational only.
        let sourceBinders: [String]
    }

    /// Imports the rows whose file-binder is in `selectedBinders` into one
    /// collection. The binder is a selection filter and nothing more: once a
    /// row is in, it is indistinguishable from any other row in the collection,
    /// and identical printings from different binders merge into one row.
    /// Reports progress in [0, 1]; yields between chunks so the main thread
    /// never stalls on a large import.
    static func apply(
        rows: [ManaBoxRow],
        selectedBinders: Set<String>,
        collectionName: String,
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

        // 0. Ensure the target collection exists.
        let existingCollections = try modelContext.fetch(
            FetchDescriptor<MTGCollection>(
                predicate: #Predicate { $0.name == collectionName }
            )
        )
        if existingCollections.isEmpty {
            modelContext.insert(MTGCollection(name: collectionName))
        }

        // 1. Replace mode: clear the entire collection, logging a removal for
        //    each copy so History and a future undo can account for it.
        if mode == .replace {
            let descriptor = FetchDescriptor<CollectionEntry>(
                predicate: #Predicate { $0.collectionName == collectionName }
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
                    collectionName: entry.collectionName,
                    finish: entry.finish,
                    condition: entry.condition,
                    quantityDelta: -entry.quantity,
                    collectionEntryID: entry.id
                ))
                modelContext.delete(entry)
            }
        }

        // 2. Add mode: index everything already in the collection so incoming
        //    rows merge into it. Keyed without binder, so a row that arrived
        //    from a different binder in an earlier import still merges.
        var existingByKey: [String: CollectionEntry] = [:]
        if mode == .add {
            let all = try modelContext.fetch(
                FetchDescriptor<CollectionEntry>(
                    predicate: #Predicate { $0.collectionName == collectionName }
                )
            )
            for entry in all { existingByKey[entry.mergeKey] = entry }
        }

        // 3. Ensure a CardMeta placeholder exists per Scryfall ID (hydrated
        //    lazily later). Track which we've seen to avoid dup inserts.
        var metaByID = Dictionary(
            try modelContext.fetch(FetchDescriptor<CardMeta>()).map { ($0.scryfallID, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        // 4. Insert/upsert rows, reporting progress and saving in batches so
        //    memory stays bounded for very large imports. Progress updates
        //    more often than saves so the bar animates smoothly.
        let saveEvery = 500
        let reportEvery = max(total / 100, 1)
        var processed = 0

        for row in relevant {
            let meta: CardMeta
            if let existing = metaByID[row.scryfallID] {
                meta = existing
            } else {
                let created = CardMeta(
                    scryfallID: row.scryfallID,
                    name: row.name,
                    setCode: row.setCode,
                    setName: row.setName,
                    collectorNumber: row.collectorNumber,
                    rarity: row.rarity
                )
                modelContext.insert(created)
                metaByID[row.scryfallID] = created
                meta = created
            }

            let entry: CollectionEntry
            let key = CollectionEntry.mergeKey(
                scryfallID: row.scryfallID, collectionName: collectionName,
                finish: row.finish.rawValue, condition: row.condition
            )
            // Also merges duplicates *within* one import: the same printing
            // listed under two selected binders lands as one row.
            if let existing = existingByKey[key] {
                existing.quantity += row.quantity
                entry = existing
            } else {
                entry = CollectionEntry(
                    scryfallID: row.scryfallID,
                    collectionName: collectionName,
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
                existingByKey[key] = entry
            }
            if entry.card == nil {
                entry.card = meta
            }

            addedCount += row.quantity
            modelContext.insert(AuditRecord(
                actionID: actionID,
                action: .importAdd,
                timestamp: now,
                scryfallID: row.scryfallID,
                cardName: row.name,
                collectionName: collectionName,
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
        CollectionChangeTracker.shared.bump()

        return Summary(
            actionID: actionID,
            added: addedCount,
            removed: removedCount,
            collectionName: collectionName,
            sourceBinders: Array(selectedBinders).sorted()
        )
    }
}
