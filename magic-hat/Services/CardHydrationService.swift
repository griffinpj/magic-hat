//
//  CardHydrationService.swift
//  magic-hat
//
//  Lazily fills in Scryfall metadata (image URLs, dimensions) for cards as
//  they approach the viewport. Reads pending IDs and writes results on the
//  main actor (SwiftData), while the network work runs off-main via the
//  Scryfall client. In-flight IDs are tracked so overlapping scroll
//  prefetches don't refetch the same card.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class CardHydrationService {
    private let client = ScryfallClient.shared
    private var inFlight: Set<String> = []

    /// Hydrates any of `scryfallIDs` whose CardMeta is still pending/failed.
    /// Safe to call repeatedly (e.g. from scroll prefetch); already-fetched
    /// and in-flight IDs are skipped.
    func hydrate(scryfallIDs: [String], context: ModelContext) {
        let candidates = Set(scryfallIDs).subtracting(inFlight)
        guard !candidates.isEmpty else { return }

        // Which candidates actually need fetching?
        let needed = neededIDs(from: candidates, context: context)
        guard !needed.isEmpty else { return }

        inFlight.formUnion(needed)

        Task {
            defer { inFlight.subtract(needed) }
            do {
                let cards = try await client.cards(ids: Array(needed))
                apply(cards: cards, context: context)
            } catch {
                markFailed(needed, context: context)
            }
        }
    }

    private func neededIDs(from ids: Set<String>, context: ModelContext) -> Set<String> {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { idList.contains($0.scryfallID) }
        )
        guard let metas = try? context.fetch(descriptor) else { return ids }
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.scryfallID, $0) })

        return ids.filter { id in
            guard let meta = byID[id] else { return true } // no meta yet
            return meta.fetchState != .fetched
        }
    }

    private func apply(cards: [ScryfallCard], context: ModelContext) {
        let ids = cards.map(\.id)
        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { ids.contains($0.scryfallID) }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.scryfallID, $0) })

        for card in cards {
            let meta = byID[card.id] ?? {
                let m = CardMeta(scryfallID: card.id)
                context.insert(m)
                byID[card.id] = m
                return m
            }()

            meta.name = card.name
            meta.setCode = card.set
            meta.setName = card.setName
            meta.collectorNumber = card.collectorNumber
            meta.rarity = card.rarity
            let uris = card.bestImageURIs
            meta.imageSmallURL = uris?.small
            meta.imageNormalURL = uris?.normal
            meta.imageLargeURL = uris?.large
            // Scryfall doesn't return pixel dims; use known constants per
            // orientation so tiles get the right aspect ratio.
            if card.isLandscape {
                meta.imageWidth = 680
                meta.imageHeight = 488
            } else {
                meta.imageWidth = 488
                meta.imageHeight = 680
            }
            meta.fetchState = .fetched
            meta.lastFetched = Date()
        }
        try? context.save()
    }

    private func markFailed(_ ids: Set<String>, context: ModelContext) {
        let idList = Array(ids)
        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { idList.contains($0.scryfallID) }
        )
        guard let metas = try? context.fetch(descriptor) else { return }
        for meta in metas where meta.fetchState != .fetched {
            meta.fetchState = .failed
        }
        try? context.save()
    }
}
