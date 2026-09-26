//
//  ImportController.swift
//  magic-hat
//
//  Applies a parsed ManaBox import into the SwiftData store and reports
//  fractional progress for the wizard's bar. Every change is recorded in the
//  append-only AuditRecord ledger under a single actionID for grouping and
//  future undo/redo.
//
//  The rows are written on CardMetaWriter's background context, not the
//  main one. They used to go through the main context, chunked with
//  Task.yield(): a 3,900-row import then left every entry, meta and audit
//  row registered in the main context, which paid for that on every
//  background save that followed (each hydration batch, each catalog
//  batch). Now the main context only ever holds what a screen fetched.
//  Progress hops to the main actor about a hundred times per import.
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
    /// collection, on the container's background writer. The binder is a
    /// selection filter and nothing more: once a row is in, it is
    /// indistinguishable from any other row in the collection, and identical
    /// printings from different binders merge into one row. Reports progress
    /// in [0, 1] on the main actor.
    static func apply(
        rows: [ManaBoxRow],
        selectedBinders: Set<String>,
        collectionName: String,
        mode: ImportMode,
        container: ModelContainer,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Summary {
        try await CardMetaWriter.shared(for: container).runImport(
            rows: rows, selectedBinders: selectedBinders, collectionName: collectionName,
            mode: mode, progress: progress
        )
    }

    /// The import itself, against whichever context the caller owns.
    nonisolated static func apply(
        rows: [ManaBoxRow],
        selectedBinders: Set<String>,
        collectionName: String,
        mode: ImportMode,
        in modelContext: ModelContext,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> Summary {
        let actionID = UUID()
        let now = Date()
        var addedCount = 0
        var removedCount = 0

        let relevant = rows.filter { selectedBinders.contains($0.binderName) && $0.quantity > 0 }
        let total = max(relevant.count, 1)

        await progress(0)

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
                    collectionEntryID: entry.id,
                    snapshot: EntrySnapshot(entry)
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
        //    Fetched by the ids the file names, in chunks: the whole table
        //    is the 112k-row catalog once ingested.
        var metaByID: [String: CardMeta] = [:]
        for chunk in Array(Set(relevant.map(\.scryfallID))).chunked(into: 500) {
            let metas = try modelContext.fetch(
                FetchDescriptor<CardMeta>(predicate: #Predicate { chunk.contains($0.scryfallID) })
            )
            for meta in metas { metaByID[meta.scryfallID] = meta }
        }

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
                collectionEntryID: entry.id,
                snapshot: EntrySnapshot(entry)
            ))

            processed += 1
            if processed % saveEvery == 0 {
                try modelContext.save()
            }
            if processed % reportEvery == 0 {
                await progress(Double(processed) / Double(total))
            }
        }

        try modelContext.save()
        await progress(1)
        await MainActor.run { CollectionChangeTracker.shared.bump() }

        return Summary(
            actionID: actionID,
            added: addedCount,
            removed: removedCount,
            collectionName: collectionName,
            sourceBinders: Array(selectedBinders).sorted()
        )
    }
}
