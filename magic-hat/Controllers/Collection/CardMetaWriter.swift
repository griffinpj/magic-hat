//
//  CardMetaWriter.swift
//  magic-hat
//
//  Every bulk write of card metadata — hydration batches, the catalog
//  ingest, rulings — goes through this ModelActor so the SwiftData save
//  happens on a background context. A 75-card batch save on the main
//  context took long enough to stall the keyboard; the catalog ingest and
//  the colour backfill (which re-hydrates a whole collection once) made it
//  continuous. The main actor only learns "something changed" via
//  CardHydrationController.revision, exactly as before.
//

import Foundation
import SwiftData

/// Own serial queue as executor — see CollectionStore for why.
actor CardMetaWriter: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private nonisolated let queue = DispatchSerialQueue(label: "magic-hat.card-meta-writer", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }

    @MainActor private static var instances: [ObjectIdentifier: CardMetaWriter] = [:]

    @MainActor
    static func shared(for container: ModelContainer) -> CardMetaWriter {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let writer = CardMetaWriter(modelContainer: container)
        instances[key] = writer
        return writer
    }

    /// Ids whose metadata is missing, failed, or stored before colours were
    /// kept (colorsRaw == nil) — what a hydration pass must fetch.
    func neededIDs(from ids: Set<String>) -> Set<String> {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { idList.contains($0.scryfallID) }
        )
        guard let metas = try? modelContext.fetch(descriptor) else { return ids }
        let byID = Dictionary(metas.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.filter { id in
            guard let meta = byID[id] else { return true }
            return meta.fetchState != .fetched || meta.colorsRaw == nil
        }
    }

    /// Upserts metadata for `cards`; with `linkEntries`, also points the
    /// collection rows that reference them at their CardMeta (hydration).
    /// The catalog ingest passes false — it writes 112k rows and the import
    /// links its own.
    func apply(cards: [ScryfallCard], linkEntries: Bool) throws {
        let ids = cards.map(\.id)
        let existing = (try? modelContext.fetch(
            FetchDescriptor<CardMeta>(predicate: #Predicate { ids.contains($0.scryfallID) })
        )) ?? []
        var byID = Dictionary(existing.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })

        for card in cards {
            let meta: CardMeta
            if let found = byID[card.id] {
                meta = found
            } else {
                let created = CardMeta(scryfallID: card.id)
                modelContext.insert(created)
                byID[card.id] = created
                meta = created
            }
            meta.apply(card)
        }

        if linkEntries {
            let descriptor = FetchDescriptor<CollectionEntry>(
                predicate: #Predicate { ids.contains($0.scryfallID) }
            )
            if let entries = try? modelContext.fetch(descriptor) {
                for entry in entries where entry.card == nil {
                    entry.card = byID[entry.scryfallID]
                }
            }
        }
        try modelContext.save()
    }

    /// A ManaBox import, on this context (see ImportController).
    func runImport(
        rows: [ManaBoxRow], selectedBinders: Set<String>, collectionName: String, mode: ImportMode,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> ImportController.Summary {
        try await ImportController.apply(
            rows: rows, selectedBinders: selectedBinders, collectionName: collectionName,
            mode: mode, in: modelContext, progress: progress
        )
    }

    /// Deleting a whole collection, on this context (see CollectionEditController).
    func runDelete(
        collectionName: String, progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> CollectionEditController.DeleteSummary {
        try await CollectionEditController.delete(collectionName: collectionName, in: modelContext, progress: progress)
    }

    /// Undo or redo of one ledger action, on this context (see LedgerReplay).
    @discardableResult
    func runReplay(actionID: UUID, direction: LedgerReplay.Direction) throws -> UUID {
        try LedgerReplay.replay(actionID: actionID, direction: direction, in: modelContext)
    }

    func markFailed(_ ids: Set<String>) throws {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { idList.contains($0.scryfallID) }
        )
        guard let metas = try? modelContext.fetch(descriptor) else { return }
        for meta in metas where meta.fetchState != .fetched {
            meta.fetchState = .failed
        }
        try modelContext.save()
    }

    func insert(rulings: [ScryfallRulingLine]) throws {
        for line in rulings {
            guard let oracleID = line.oracleId else { continue }
            modelContext.insert(CardRuling(
                oracleID: oracleID,
                source: line.source ?? "scryfall",
                publishedAt: line.publishedAt ?? "",
                comment: line.comment ?? ""
            ))
        }
        try modelContext.save()
    }
}
