//
//  CardHydrationController.swift
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
import UIKit

@MainActor
@Observable
final class CardHydrationController {
    /// Shared so an import and the collection screen cooperate on one
    /// `hydrated` set instead of refetching each other's work.
    static let shared = CardHydrationController()

    /// How long Scryfall prices stay fresh before a refresh is offered.
    static let priceTTL: TimeInterval = 6 * 3600

    private let client = ScryfallClient.shared
    private var inFlight: Set<String> = []
    /// IDs known-fetched this session, so repeated scroll prefetches short
    /// circuit without a SwiftData fetch on the main thread.
    private var hydrated: Set<String> = []

    /// Progress of a full-collection sync (see `hydrateAll`).
    private(set) var isSyncing = false
    private(set) var syncedCount = 0
    private(set) var syncTotal = 0
    var syncFraction: Double {
        syncTotal > 0 ? Double(syncedCount) / Double(syncTotal) : 0
    }

    /// Hydrates metadata for EVERY id in the collection, in batches of 75.
    ///
    /// Viewport-only hydration left most cards without a price or rarity, so
    /// sorting by those keys operated on mostly-empty data. Fetching the whole
    /// collection once (then cached in SwiftData forever) makes every sort
    /// correct and makes collection value computable. Applies per chunk so the
    /// grid fills in progressively.
    func hydrateAll(scryfallIDs: [String], context: ModelContext) async {
        guard !isSyncing else { return }
        let all = Set(scryfallIDs).subtracting(hydrated)
        guard !all.isEmpty else { return }

        let needed = neededIDs(from: all, context: context)
        hydrated.formUnion(all.subtracting(needed))
        guard !needed.isEmpty else { return }

        isSyncing = true
        syncTotal = needed.count
        syncedCount = 0

        // Keep going for a short while if the user backgrounds the app; the
        // work is idempotent, so whatever doesn't finish resumes on next open.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "card-sync")
        defer {
            isSyncing = false
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        }

        for chunk in Array(needed).chunked(into: ScryfallClient.collectionBatchSize) {
            if Task.isCancelled { return }
            do {
                let response = try await client.collection(ids: chunk)
                apply(cards: response.data, context: context)
                hydrated.formUnion(chunk)
            } catch {
                markFailed(Set(chunk), context: context)
            }
            syncedCount += chunk.count
        }
    }

    /// Re-fetches prices for cards whose prices are older than `priceTTL`.
    /// Card metadata is effectively immutable, so this exists separately: only
    /// the money moves. Uses the same batched endpoint and reports progress.
    @discardableResult
    func refreshStalePrices(scryfallIDs: [String], context: ModelContext) async -> Int {
        guard !isSyncing else { return 0 }
        let cutoff = Date().addingTimeInterval(-Self.priceTTL)
        let idSet = Set(scryfallIDs)
        let idList = Array(idSet)

        let descriptor = FetchDescriptor<CardMeta>(
            predicate: #Predicate { idList.contains($0.scryfallID) }
        )
        guard let metas = try? context.fetch(descriptor) else { return 0 }
        let stale = metas
            .filter { $0.fetchState == .fetched && ($0.pricesUpdatedAt ?? .distantPast) < cutoff }
            .map(\.scryfallID)
        guard !stale.isEmpty else { return 0 }

        isSyncing = true
        syncTotal = stale.count
        syncedCount = 0
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "price-refresh")
        defer {
            isSyncing = false
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        }

        var updated = 0
        for chunk in stale.chunked(into: ScryfallClient.collectionBatchSize) {
            if Task.isCancelled { return updated }
            if let response = try? await client.collection(ids: chunk) {
                apply(cards: response.data, context: context)
                updated += response.data.count
            }
            syncedCount += chunk.count
        }
        return updated
    }

    /// Hydrates any of `scryfallIDs` whose CardMeta is still pending/failed.
    /// Safe to call on every tile's onAppear; already-known and in-flight IDs
    /// are skipped with pure set math (no DB query).
    func hydrate(scryfallIDs: [String], context: ModelContext) {
        var candidates = Set(scryfallIDs)
        candidates.subtract(hydrated)
        candidates.subtract(inFlight)
        guard !candidates.isEmpty else { return }

        // Only unknown IDs hit the store (covers metadata cached across
        // launches). This is the sole DB touch and runs rarely during scroll.
        let needed = neededIDs(from: candidates, context: context)

        // Anything already fetched in the store: remember and skip.
        hydrated.formUnion(candidates.subtracting(needed))
        guard !needed.isEmpty else { return }

        inFlight.formUnion(needed)

        Task {
            defer { inFlight.subtract(needed) }
            do {
                let cards = try await client.cards(ids: Array(needed))
                apply(cards: cards, context: context)
                hydrated.formUnion(needed)
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
            meta.oracleID = card.oracleID
            meta.typeLine = card.bestTypeLine
            meta.manaCost = card.bestManaCost
            meta.oracleText = card.bestOracleText
            meta.power = card.power
            meta.toughness = card.toughness
            meta.priceUSD = card.prices?.usd.flatMap(Double.init)
            meta.priceUSDFoil = card.prices?.usdFoil.flatMap(Double.init)
            meta.pricesUpdatedAt = Date()
            let uris = card.bestImageURIs
            meta.imageSmallURL = uris?.small
            meta.imageNormalURL = uris?.normal
            meta.imageLargeURL = uris?.large
            meta.artCropURL = uris?.artCrop
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
