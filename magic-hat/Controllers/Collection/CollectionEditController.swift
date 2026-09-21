//
//  CollectionEditController.swift
//  magic-hat
//
//  Structural edits to a collection. Deletion writes the removal into the
//  append-only AuditRecord ledger first, one record per entry, so History
//  still explains where the cards went and a future undo has something to
//  work from. Like the import it chunks and yields, because deleting a few
//  thousand rows on the main context would otherwise stall the run loop.
//

import Foundation
import SwiftData

@MainActor
enum CollectionEditController {
    struct DeleteSummary: Sendable {
        let actionID: UUID
        let collectionName: String
        let removedCopies: Int
        let removedRows: Int
    }

    @discardableResult
    static func delete(
        collectionName: String,
        context modelContext: ModelContext,
        progress: (Double) -> Void = { _ in }
    ) async throws -> DeleteSummary {
        let actionID = UUID()
        let now = Date()

        let entries = try modelContext.fetch(
            FetchDescriptor<CollectionEntry>(
                predicate: #Predicate { $0.collectionName == collectionName }
            )
        )
        let total = max(entries.count, 1)
        var removedCopies = 0
        var processed = 0

        for entry in entries {
            removedCopies += entry.quantity
            modelContext.insert(AuditRecord(
                actionID: actionID,
                action: .manualRemove,
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

            processed += 1
            if processed % 500 == 0 {
                try modelContext.save()
                await Task.yield()
            }
            if processed % max(total / 100, 1) == 0 {
                progress(Double(processed) / Double(total))
            }
        }

        // Finally the collection itself. CardMeta is deliberately left alone:
        // it is a shared cache keyed by Scryfall id, useful to any other
        // collection and cheap to keep.
        let collections = try modelContext.fetch(
            FetchDescriptor<MTGCollection>(
                predicate: #Predicate { $0.name == collectionName }
            )
        )
        for collection in collections { modelContext.delete(collection) }

        try modelContext.save()
        progress(1)

        return DeleteSummary(
            actionID: actionID,
            collectionName: collectionName,
            removedCopies: removedCopies,
            removedRows: entries.count
        )
    }
}
