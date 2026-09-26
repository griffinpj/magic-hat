//
//  CollectionEditController.swift
//  magic-hat
//
//  Edits to a collection that aren't an import: adding a printing, changing
//  an entry, removing one, deleting a whole collection. Every change writes
//  to the append-only AuditRecord ledger under one actionID and bumps
//  CollectionChangeTracker so snapshot-backed views refetch.
//
//  Identity is CollectionEntry.mergeKey (card + collection + finish +
//  condition). Adding a printing that already matches a row raises its
//  quantity; editing a row so its identity now matches another row merges
//  them. That is the same rule the import uses, so the collection can never
//  hold two rows that mean the same thing.
//

import Foundation
import SwiftData

@MainActor
enum CollectionEditController {
    nonisolated struct DeleteSummary: Sendable {
        let actionID: UUID
        let collectionName: String
        let removedCopies: Int
        let removedRows: Int
    }

    /// Deletes a whole collection on the background writer's context: every
    /// row and an AuditRecord per row, 3,900 of each for the real export.
    /// On the main context this held the main thread for seconds (a save
    /// per 500 rows, with a yield between, was still seconds of saves).
    @discardableResult
    static func delete(
        collectionName: String,
        context: ModelContext,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws -> DeleteSummary {
        try await CardMetaWriter.shared(for: context.container).runDelete(collectionName: collectionName, progress: progress)
    }

    /// The delete itself, on whatever context it is given (the writer's).
    @discardableResult
    nonisolated static func delete(
        collectionName: String,
        in modelContext: ModelContext,
        progress: @escaping @MainActor @Sendable (Double) -> Void
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
                collectionEntryID: entry.id,
                snapshot: EntrySnapshot(entry)
            ))
            modelContext.delete(entry)

            processed += 1
            if processed % 500 == 0 {
                try modelContext.save()
            }
            if processed % max(total / 100, 1) == 0 {
                await progress(Double(processed) / Double(total))
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
        await progress(1)
        await MainActor.run { CollectionChangeTracker.shared.bump() }

        return DeleteSummary(
            actionID: actionID,
            collectionName: collectionName,
            removedCopies: removedCopies,
            removedRows: entries.count
        )
    }
}

// MARK: - Single-entry edits

nonisolated enum CollectionEditError: Error, LocalizedError {
    case invalidQuantity
    case missingCollection
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .invalidQuantity: return "Quantity must be at least 1."
        case .missingCollection: return "Choose a collection."
        case .entryNotFound: return "That card is no longer in the collection."
        }
    }
}

extension CollectionEditController {
    struct AddRequest: Sendable {
        var printing: PrintingSelection
        var collectionName: String
        var quantity: Int = 1
        var finish: CardFinish = .normal
        var condition: String = CardCondition.nearMint.rawValue
        var language: String = "en"
        var purchasePrice: Double?
    }

    struct EntryEdits: Sendable {
        var quantity: Int
        var finish: CardFinish
        var condition: String
        var language: String
        var purchasePrice: Double?
    }

    /// Adds copies of a printing to a collection. Merges into an existing
    /// row with the same identity; otherwise creates one. Returns the
    /// actionID the audit records were written under.
    @discardableResult
    static func add(_ request: AddRequest, context modelContext: ModelContext) throws -> UUID {
        guard request.quantity > 0 else { throw CollectionEditError.invalidQuantity }
        let collectionName = request.collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collectionName.isEmpty else { throw CollectionEditError.missingCollection }

        let actionID = UUID()
        let now = Date()
        try ensureCollection(named: collectionName, context: modelContext)
        let meta = try ensureMeta(for: request.printing, context: modelContext)

        let key = CollectionEntry.mergeKey(
            scryfallID: request.printing.scryfallID, collectionName: collectionName,
            finish: request.finish.rawValue, condition: request.condition
        )
        let scryfallID = request.printing.scryfallID
        let candidates = try modelContext.fetch(FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.collectionName == collectionName && $0.scryfallID == scryfallID }
        ))

        let entry: CollectionEntry
        if let existing = candidates.first(where: { $0.mergeKey == key }) {
            existing.quantity += request.quantity
            if existing.purchasePrice == nil { existing.purchasePrice = request.purchasePrice }
            entry = existing
        } else {
            entry = CollectionEntry(
                scryfallID: scryfallID,
                collectionName: collectionName,
                name: request.printing.name,
                setCode: request.printing.setCode,
                setName: request.printing.setName,
                collectorNumber: request.printing.collectorNumber,
                rarity: request.printing.rarity,
                finish: request.finish,
                quantity: request.quantity,
                condition: request.condition,
                language: request.language,
                purchasePrice: request.purchasePrice,
                purchasePriceCurrency: request.purchasePrice == nil ? nil : "USD",
                addedDate: now
            )
            modelContext.insert(entry)
        }
        if entry.card == nil { entry.card = meta }

        modelContext.insert(AuditRecord(
            actionID: actionID, action: .manualAdd, timestamp: now,
            scryfallID: scryfallID, cardName: request.printing.name,
            collectionName: collectionName, finish: request.finish,
            condition: request.condition, quantityDelta: request.quantity,
            collectionEntryID: entry.id, snapshot: EntrySnapshot(entry)
        ))
        try modelContext.save()
        CollectionChangeTracker.shared.bump()
        return actionID
    }

    /// Applies edits to one entry. If the edits change its identity to match
    /// another row in the same collection, the two merge.
    static func update(entryID: UUID, edits: EntryEdits, context modelContext: ModelContext) throws {
        guard edits.quantity > 0 else { throw CollectionEditError.invalidQuantity }
        guard let entry = try fetchEntry(entryID, context: modelContext) else {
            throw CollectionEditError.entryNotFound
        }
        let actionID = UUID()
        let now = Date()
        let oldKey = entry.mergeKey
        let oldQuantity = entry.quantity
        let oldFinish = entry.finish
        let oldCondition = entry.condition

        entry.quantity = edits.quantity
        entry.finish = edits.finish
        entry.condition = edits.condition
        entry.language = edits.language
        entry.purchasePrice = edits.purchasePrice
        if edits.purchasePrice != nil, entry.purchasePriceCurrency == nil { entry.purchasePriceCurrency = "USD" }

        let identityChanged = entry.mergeKey != oldKey
        if identityChanged {
            let collectionName = entry.collectionName
            let scryfallID = entry.scryfallID
            let newKey = entry.mergeKey
            let siblings = try modelContext.fetch(FetchDescriptor<CollectionEntry>(
                predicate: #Predicate { $0.collectionName == collectionName && $0.scryfallID == scryfallID }
            ))
            // Ledger: the old identity loses its copies, the new one gains them.
            modelContext.insert(AuditRecord(
                actionID: actionID, action: .manualRemove, timestamp: now,
                scryfallID: scryfallID, cardName: entry.name, collectionName: collectionName,
                finish: oldFinish, condition: oldCondition, quantityDelta: -oldQuantity,
                collectionEntryID: entry.id, snapshot: EntrySnapshot(entry)
            ))
            if let other = siblings.first(where: { $0.id != entry.id && $0.mergeKey == newKey }) {
                other.quantity += entry.quantity
                if other.purchasePrice == nil { other.purchasePrice = entry.purchasePrice }
                modelContext.insert(AuditRecord(
                    actionID: actionID, action: .manualAdd, timestamp: now,
                    scryfallID: scryfallID, cardName: entry.name, collectionName: collectionName,
                    finish: edits.finish, condition: edits.condition, quantityDelta: entry.quantity,
                    collectionEntryID: other.id, snapshot: EntrySnapshot(other)
                ))
                modelContext.delete(entry)
            } else {
                modelContext.insert(AuditRecord(
                    actionID: actionID, action: .manualAdd, timestamp: now,
                    scryfallID: scryfallID, cardName: entry.name, collectionName: collectionName,
                    finish: edits.finish, condition: edits.condition, quantityDelta: entry.quantity,
                    collectionEntryID: entry.id, snapshot: EntrySnapshot(entry)
                ))
            }
        } else if entry.quantity != oldQuantity {
            let delta = entry.quantity - oldQuantity
            modelContext.insert(AuditRecord(
                actionID: actionID, action: delta > 0 ? .manualAdd : .manualRemove, timestamp: now,
                scryfallID: entry.scryfallID, cardName: entry.name, collectionName: entry.collectionName,
                finish: entry.finish, condition: entry.condition, quantityDelta: delta,
                collectionEntryID: entry.id, snapshot: EntrySnapshot(entry)
            ))
        }

        try modelContext.save()
        CollectionChangeTracker.shared.bump()
    }

    /// Removes one entry entirely, recording the removal.
    static func remove(entryID: UUID, context modelContext: ModelContext) throws {
        guard let entry = try fetchEntry(entryID, context: modelContext) else {
            throw CollectionEditError.entryNotFound
        }
        modelContext.insert(AuditRecord(
            actionID: UUID(), action: .manualRemove, timestamp: Date(),
            scryfallID: entry.scryfallID, cardName: entry.name, collectionName: entry.collectionName,
            finish: entry.finish, condition: entry.condition, quantityDelta: -entry.quantity,
            collectionEntryID: entry.id, snapshot: EntrySnapshot(entry)
        ))
        modelContext.delete(entry)
        try modelContext.save()
        CollectionChangeTracker.shared.bump()
    }

    /// Creates an empty collection. Returns false if the name is taken
    /// (case-insensitively) or blank.
    @discardableResult
    static func createCollection(named raw: String, context modelContext: ModelContext) throws -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let all = try modelContext.fetch(FetchDescriptor<MTGCollection>())
        guard !all.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        modelContext.insert(MTGCollection(name: name))
        try modelContext.save()
        CollectionChangeTracker.shared.bump()
        return true
    }

    // MARK: Helpers

    private static func fetchEntry(_ id: UUID, context: ModelContext) throws -> CollectionEntry? {
        try context.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.id == id })).first
    }

    private static func ensureCollection(named name: String, context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<MTGCollection>(predicate: #Predicate { $0.name == name }))
        if existing.isEmpty { context.insert(MTGCollection(name: name)) }
    }

    /// The shared CardMeta for a printing; created as a pending placeholder
    /// (carrying what the selection already knows) if we've never seen it,
    /// so the grid can show it immediately and hydration fills the rest.
    private static func ensureMeta(for printing: PrintingSelection, context: ModelContext) throws -> CardMeta {
        let id = printing.scryfallID
        if let existing = try context.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { $0.scryfallID == id })).first {
            return existing
        }
        let meta = CardMeta(
            scryfallID: id, name: printing.name, setCode: printing.setCode,
            setName: printing.setName, collectorNumber: printing.collectorNumber,
            rarity: printing.rarity,
            imageWidth: printing.aspectRatio > 1 ? 680 : 488,
            imageHeight: printing.aspectRatio > 1 ? 488 : 680
        )
        meta.oracleID = printing.oracleID
        meta.imageNormalURL = printing.imageURL
        meta.artCropURL = printing.artCropURL
        meta.priceUSD = printing.priceUSD
        meta.priceUSDFoil = printing.priceUSDFoil
        context.insert(meta)
        return meta
    }
}
