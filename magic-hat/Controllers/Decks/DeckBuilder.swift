//
//  DeckBuilder.swift
//  magic-hat
//
//  Moves physical cards between collections and a deck's hidden
//  collection. `plan` decides what to take from where; `build` performs the
//  moves; `disassemble` returns everything to where it came from. Every
//  copy is decremented in one row and incremented in another under one
//  actionID with paired AuditRecords, so counts are conserved and History
//  can show (and later undo) the move. Runs on a background context.
//

import Foundation
import SwiftData

/// Own serial queue as executor — see CollectionStore for why.
actor DeckBuilder: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    private nonisolated let queue = DispatchSerialQueue(label: "magic-hat.deck-builder", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(modelContainer))
    }

    @MainActor private static var instances: [ObjectIdentifier: DeckBuilder] = [:]

    @MainActor
    static func shared(for container: ModelContainer) -> DeckBuilder {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let builder = DeckBuilder(modelContainer: container)
        instances[key] = builder
        return builder
    }

    enum BuildError: Error, LocalizedError {
        case deckNotFound
        var errorDescription: String? { "The deck no longer exists." }
    }

    // MARK: Plan

    /// What the collections can supply for what the deck still lacks.
    /// `sourceCollections` nil means every real collection.
    func plan(deckID: UUID, sourceCollections: [String]?, includeSideboard: Bool) throws -> BuildPlan {
        guard let deck = try fetchDeck(deckID) else { throw BuildError.deckNotFound }
        let wanted = deck.cards.filter { $0.board.isPlayed || (includeSideboard && $0.board == .side) }
            .sorted { boardRank($0.board) < boardRank($1.board) }
        let ids = Array(Set(wanted.map(\.scryfallID)))
        let metas = try modelContext.fetch(FetchDescriptor<CardMeta>(predicate: #Predicate { ids.contains($0.scryfallID) }))
        let metaByID = Dictionary(metas.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })
        func matchKey(_ card: DeckCard) -> String { card.oracleID ?? metaByID[card.scryfallID]?.oracleID ?? card.scryfallID }
        let keys = Set(wanted.map(matchKey))

        // Already in the deck.
        let deckKey = deck.collectionKey
        var built = try entriesByKey(#Predicate { $0.collectionName == deckKey }, keys: keys)
            .mapValues { $0.reduce(0) { $0 + $1.quantity } }

        // Candidates: real collections (or the chosen ones).
        let sources: [CollectionEntry]
        if let names = sourceCollections {
            sources = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { names.contains($0.collectionName) }))
        } else {
            sources = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { !$0.collectionName.starts(with: "deck:") }))
        }
        var remaining: [UUID: Int] = [:]
        var candidatesByKey: [String: [CollectionEntry]] = [:]
        for entry in sources where entry.quantity > 0 {
            let key = entry.card?.oracleID ?? entry.scryfallID
            guard keys.contains(key) else { continue }
            candidatesByKey[key, default: []].append(entry)
            remaining[entry.id] = entry.quantity
        }

        var entries: [BuildPlanEntry] = []
        for card in wanted {
            let key = matchKey(card)
            let alreadyBuilt = min(card.quantity, built[key] ?? 0)
            built[key, default: 0] -= alreadyBuilt
            var needed = card.quantity - alreadyBuilt
            guard needed > 0 else { continue }

            // Exact printing first, then non-foils (keep foils in the binder
            // unless nothing else), then the largest stack.
            let candidates = (candidatesByKey[key] ?? []).sorted { a, b in
                let aExact = a.scryfallID == card.scryfallID, bExact = b.scryfallID == card.scryfallID
                if aExact != bExact { return aExact }
                let aFoil = a.finish != .normal, bFoil = b.finish != .normal
                if aFoil != bFoil { return !aFoil }
                return (remaining[a.id] ?? 0) > (remaining[b.id] ?? 0)
            }
            var takes: [BuildTake] = []
            for entry in candidates where needed > 0 {
                let have = remaining[entry.id] ?? 0
                guard have > 0 else { continue }
                let take = min(have, needed)
                remaining[entry.id] = have - take
                needed -= take
                takes.append(BuildTake(
                    entryID: entry.id, fromCollection: entry.collectionName,
                    printingLabel: "\(entry.setCode.uppercased()) #\(entry.collectorNumber)\(entry.finish == .normal ? "" : " · \(entry.finish.displayName)")",
                    quantity: take
                ))
            }
            entries.append(BuildPlanEntry(id: card.id, name: card.name, board: card.board,
                                          needed: card.quantity - alreadyBuilt, takes: takes))
        }

        let sourceNames = sourceCollections ?? Array(Set(sources.map(\.collectionName))).sorted()
        return BuildPlan(deckID: deck.id, deckName: deck.name, sourceCollections: sourceNames,
                         includeSideboard: includeSideboard, entries: entries)
    }

    // MARK: Build

    func build(_ plan: BuildPlan) throws -> BuildResult {
        guard let deck = try fetchDeck(plan.deckID) else { throw BuildError.deckNotFound }
        let actionID = UUID()
        let now = Date()
        let deckKey = deck.collectionKey
        var moved = 0

        let entryIDs = Array(Set(plan.entries.flatMap { $0.takes.map(\.entryID) }))
        let sourceEntries = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { entryIDs.contains($0.id) }))
        let sourceByID = Dictionary(sourceEntries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var deckEntries = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == deckKey }))

        for planEntry in plan.entries {
            for take in planEntry.takes {
                guard let source = sourceByID[take.entryID] else { continue }
                // The collection may have changed since the plan was made.
                let n = min(take.quantity, source.quantity)
                guard n > 0 else { continue }

                let key = CollectionEntry.mergeKey(scryfallID: source.scryfallID, collectionName: deckKey,
                                                   finish: source.finishRaw, condition: source.condition)
                let target: CollectionEntry
                if let existing = deckEntries.first(where: { $0.mergeKey == key }) {
                    existing.quantity += n
                    target = existing
                } else {
                    let created = CollectionEntry(
                        scryfallID: source.scryfallID, collectionName: deckKey,
                        name: source.name, setCode: source.setCode, setName: source.setName,
                        collectorNumber: source.collectorNumber, rarity: source.rarity,
                        finish: source.finish, quantity: n, condition: source.condition,
                        language: source.language, purchasePrice: source.purchasePrice,
                        purchasePriceCurrency: source.purchasePriceCurrency, manaBoxID: source.manaBoxID,
                        addedDate: now
                    )
                    created.card = source.card
                    created.sourceCollectionName = source.collectionName
                    modelContext.insert(created)
                    deckEntries.append(created)
                    target = created
                }

                // The deck's row is recorded under its key, not the "Deck:
                // Name" label (History labels it): undo needs the collection.
                modelContext.insert(AuditRecord(
                    actionID: actionID, action: .deckBuild, timestamp: now,
                    scryfallID: source.scryfallID, cardName: source.name, collectionName: source.collectionName,
                    finish: source.finish, condition: source.condition, quantityDelta: -n, collectionEntryID: source.id,
                    snapshot: EntrySnapshot(source)
                ))
                modelContext.insert(AuditRecord(
                    actionID: actionID, action: .deckBuild, timestamp: now,
                    scryfallID: source.scryfallID, cardName: source.name, collectionName: deckKey,
                    finish: source.finish, condition: source.condition, quantityDelta: n, collectionEntryID: target.id,
                    snapshot: EntrySnapshot(target)
                ))

                source.quantity -= n
                if source.quantity == 0 { modelContext.delete(source) }
                moved += n
            }
        }
        deck.updatedDate = now
        try modelContext.save()
        return BuildResult(actionID: actionID, movedCopies: moved, missingCopies: plan.missingCopies)
    }

    // MARK: Disassemble

    /// Returns every built copy to the collection it came from (or the
    /// first collection, if that one is gone), merging by mergeKey.
    func disassemble(deckID: UUID) throws -> DisassembleResult {
        guard let deck = try fetchDeck(deckID) else { throw BuildError.deckNotFound }
        let actionID = UUID()
        let now = Date()
        let deckKey = deck.collectionKey
        let deckEntries = try modelContext.fetch(FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == deckKey }))
        guard !deckEntries.isEmpty else { return DisassembleResult(actionID: actionID, returnedCopies: 0) }

        let collections = try modelContext.fetch(FetchDescriptor<MTGCollection>(sortBy: [SortDescriptor(\.name)]))
        var collectionNames = Set(collections.map(\.name))
        let fallback = collections.first?.name ?? "My Collection"
        if collections.isEmpty {
            modelContext.insert(MTGCollection(name: fallback))
            collectionNames.insert(fallback)
        }

        let ids = Array(Set(deckEntries.map(\.scryfallID)))
        let existingTargets = try modelContext.fetch(FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { ids.contains($0.scryfallID) && !$0.collectionName.starts(with: "deck:") }
        ))
        var targetByKey = Dictionary(existingTargets.map { ($0.mergeKey, $0) }, uniquingKeysWith: { a, _ in a })

        var returned = 0
        for entry in deckEntries {
            var home = entry.sourceCollectionName ?? fallback
            if !collectionNames.contains(home) { home = fallback }
            let key = CollectionEntry.mergeKey(scryfallID: entry.scryfallID, collectionName: home,
                                               finish: entry.finishRaw, condition: entry.condition)
            let target: CollectionEntry
            if let existing = targetByKey[key] {
                existing.quantity += entry.quantity
                target = existing
            } else {
                let created = CollectionEntry(
                    scryfallID: entry.scryfallID, collectionName: home,
                    name: entry.name, setCode: entry.setCode, setName: entry.setName,
                    collectorNumber: entry.collectorNumber, rarity: entry.rarity,
                    finish: entry.finish, quantity: entry.quantity, condition: entry.condition,
                    language: entry.language, purchasePrice: entry.purchasePrice,
                    purchasePriceCurrency: entry.purchasePriceCurrency, manaBoxID: entry.manaBoxID,
                    addedDate: entry.addedDate ?? now
                )
                created.card = entry.card
                modelContext.insert(created)
                targetByKey[key] = created
                target = created
            }
            modelContext.insert(AuditRecord(
                actionID: actionID, action: .deckDisassemble, timestamp: now,
                scryfallID: entry.scryfallID, cardName: entry.name, collectionName: deckKey,
                finish: entry.finish, condition: entry.condition, quantityDelta: -entry.quantity, collectionEntryID: entry.id,
                snapshot: EntrySnapshot(entry)
            ))
            modelContext.insert(AuditRecord(
                actionID: actionID, action: .deckDisassemble, timestamp: now,
                scryfallID: entry.scryfallID, cardName: entry.name, collectionName: home,
                finish: entry.finish, condition: entry.condition, quantityDelta: entry.quantity, collectionEntryID: target.id,
                snapshot: EntrySnapshot(target)
            ))
            returned += entry.quantity
            modelContext.delete(entry)
        }
        deck.updatedDate = now
        try modelContext.save()
        return DisassembleResult(actionID: actionID, returnedCopies: returned)
    }

    // MARK: Helpers

    private func fetchDeck(_ id: UUID) throws -> Deck? {
        try modelContext.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
    }

    private func boardRank(_ board: DeckBoard) -> Int {
        switch board {
        case .commander: return 0
        case .main: return 1
        case .side: return 2
        case .maybe: return 3
        }
    }

    private func entriesByKey(_ predicate: Predicate<CollectionEntry>, keys: Set<String>) throws -> [String: [CollectionEntry]] {
        var descriptor = FetchDescriptor<CollectionEntry>(predicate: predicate)
        descriptor.relationshipKeyPathsForPrefetching = [\.card]
        var out: [String: [CollectionEntry]] = [:]
        for entry in try modelContext.fetch(descriptor) {
            let key = entry.card?.oracleID ?? entry.scryfallID
            if keys.contains(key) { out[key, default: []].append(entry) }
        }
        return out
    }
}
