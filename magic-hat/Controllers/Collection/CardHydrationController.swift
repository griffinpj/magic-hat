//
//  CardHydrationController.swift
//  magic-hat
//
//  Lazily fills in Scryfall metadata (image URLs, dimensions) for cards as
//  they approach the viewport. The network work runs off-main via the
//  Scryfall client and the SwiftData writes go through CardMetaWriter (a
//  ModelActor), so nothing here blocks the main thread; only the
//  bookkeeping and `revision` live on the main actor. In-flight IDs are
//  tracked so overlapping scroll prefetches don't refetch the same card.
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

    private let client = ScryfallClient.shared
    private var inFlight: Set<String> = []
    /// IDs known-fetched this session, so repeated scroll prefetches short
    /// circuit without a SwiftData fetch on the main thread.
    private var hydrated: Set<String> = []

    /// Progress of a full-collection sync (see `hydrateAll`).
    /// Bumped whenever metadata is written. Views observe this to rebuild,
    /// instead of holding a second unbounded @Query over every CardMeta row.
    private(set) var revision = 0

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

        let needed = await writer(context).neededIDs(from: all)
        hydrated.formUnion(all.subtracting(needed))
        guard !needed.isEmpty else { return }

        await run(needed: needed, context: context)
    }

    private func writer(_ context: ModelContext) -> CardMetaWriter {
        CardMetaWriter.shared(for: context.container)
    }

    /// Same as `hydrateAll`, but the caller already knows which ids are
    /// pending (CollectionStore works it out while building the snapshot), so
    /// no store round-trip is made here at all.
    func hydrate(pending ids: [String], context: ModelContext) async {
        guard !isSyncing else { return }
        let needed = Set(ids).subtracting(hydrated)
        guard !needed.isEmpty else { return }
        await run(needed: needed, context: context)
    }

    private func run(needed: Set<String>, context: ModelContext) async {
        isSyncing = true
        syncTotal = needed.count
        syncedCount = 0
        // Register with the viewport prefetcher so tiles appearing mid-sync
        // don't request the same ids a second time.
        inFlight.formUnion(needed)

        // Keep going for a short while if the user backgrounds the app; the
        // work is idempotent, so whatever doesn't finish resumes on next open.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "card-sync")
        defer {
            isSyncing = false
            inFlight.subtract(needed)
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
        }

        for chunk in Array(needed).chunked(into: ScryfallClient.collectionBatchSize) {
            if Task.isCancelled { return }
            do {
                let response = try await client.collection(ids: chunk)
                await apply(cards: response.data, context: context)
                hydrated.formUnion(chunk)
            } catch {
                try? await writer(context).markFailed(Set(chunk))
            }
            syncedCount += chunk.count
        }
    }

    /// Re-fetches prices for ids the caller already knows are stale (the store
    /// computes them alongside the snapshot). Card metadata is effectively
    /// immutable, so this exists separately: only the money moves.
    @discardableResult
    func refreshPrices(stale ids: [String], context: ModelContext) async -> Int {
        guard !isSyncing else { return 0 }
        let stale = Array(Set(ids))
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
                await apply(cards: response.data, context: context)
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
        // Membership tests over the window, not `subtract`, which walks
        // the *other* set: with 3,900 ids hydrated that was 0.12s per
        // tile appearing (HangDetector, real collection).
        var candidates = Set<String>()
        for id in scryfallIDs where !hydrated.contains(id) && !inFlight.contains(id) { candidates.insert(id) }
        guard !candidates.isEmpty else { return }

        // Claim them now so a scroll that fires again before the store
        // answers doesn't start a second lookup for the same tiles.
        inFlight.formUnion(candidates)

        Task {
            // Only unknown IDs hit the store (covers metadata cached across
            // launches); the lookup runs on the writer, off the main thread.
            let needed = await writer(context).neededIDs(from: candidates)
            hydrated.formUnion(candidates.subtracting(needed))
            inFlight.subtract(candidates.subtracting(needed))
            guard !needed.isEmpty else { return }
            defer { inFlight.subtract(needed) }
            do {
                let cards = try await client.cards(ids: Array(needed))
                await apply(cards: cards, context: context)
                hydrated.formUnion(needed)
            } catch {
                try? await writer(context).markFailed(needed)
            }
        }
    }

    /// Writes a batch on the background context, then bumps `revision` so
    /// views refetch. Failures are swallowed here as they were on the main
    /// context: the rows stay pending and the next pass retries.
    private func apply(cards: [ScryfallCard], context: ModelContext) async {
        try? await writer(context).apply(cards: cards, linkEntries: true)
        revision &+= 1
    }
}
