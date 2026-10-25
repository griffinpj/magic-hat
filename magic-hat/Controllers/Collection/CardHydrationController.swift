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
    /// What the running sync is doing, for the grid's pill.
    private(set) var syncLabel = "Syncing"
    /// The sync in progress (`sync(pending:stale:context:)`), owned here
    /// rather than by the screen that asked for it: a collection's `.task`
    /// used to await the whole run, so backing out of the grid — or any
    /// write bumping the tracker — cancelled a half-done price refresh.
    private(set) var syncTask: Task<Void, Never>?
    /// Which queued run `syncTask` stands for: only the last one clears it.
    private var syncGeneration = 0
    var syncFraction: Double {
        syncTotal > 0 ? Double(syncedCount) / Double(syncTotal) : 0
    }

    /// Runs `work` after whatever is already queued, as the one owned task.
    /// Every full run comes through here — a screen's `sync`, the import
    /// wizard's `hydrateAll`, Settings' forced price refresh — so
    /// `syncTask` always ends with the last of them. The wizard's run and
    /// the forced refresh used to run beside it: a grid opened mid-import
    /// awaited a nil task and never re-sorted once prices and rarities
    /// landed. Queued, not dropped: what the later run still needs it
    /// works out when its turn comes (most of it is `hydrated` by then).
    private func enqueue<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = syncTask
        syncGeneration &+= 1
        let generation = syncGeneration
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        syncTask = Task { @MainActor [weak self] in
            _ = await task.value
            if self?.syncGeneration == generation { self?.syncTask = nil }
        }
        return task
    }

    /// Hydrates metadata for EVERY id in the collection, in batches of 75,
    /// in the order given (the wizard passes the file's).
    ///
    /// Viewport-only hydration left most cards without a price or rarity, so
    /// sorting by those keys operated on mostly-empty data. Fetching the whole
    /// collection once (then cached in SwiftData forever) makes every sort
    /// correct and makes collection value computable. Applies per chunk so the
    /// grid fills in progressively. Queued behind a sync already running and
    /// awaited to its end; the caller can tell by `syncTask` being set first.
    func hydrateAll(scryfallIDs: [String], context: ModelContext) async {
        await enqueue { await self.hydrateAllNow(scryfallIDs: scryfallIDs, context: context) }.value
    }

    private func hydrateAllNow(scryfallIDs: [String], context: ModelContext) async {
        var seen = Set<String>()
        let ordered = scryfallIDs.filter { !hydrated.contains($0) && seen.insert($0).inserted }
        guard !ordered.isEmpty else { return }
        let needed = await writer(context).neededIDs(from: seen)
        hydrated.formUnion(seen.subtracting(needed))
        let queue = ordered.filter(needed.contains)
        guard !queue.isEmpty else { return }
        await run(queue, context: context)
    }

    private func writer(_ context: ModelContext) -> CardMetaWriter {
        CardMetaWriter.shared(for: context.container)
    }

    /// Metadata for `pending`, then prices for `stale`, as one run the
    /// controller owns. A screen calls it and carries on; it can await
    /// `syncTask?.value` for the end without its own cancellation
    /// reaching the run. A run already going (or queued) is left alone:
    /// the grid and the app-level refresh both ask on every open.
    /// `pending` is fetched in the order given — the grid passes its
    /// snapshot's, so the first screen fills first.
    func sync(pending: [String], stale: [String], context: ModelContext) {
        guard syncTask == nil, !isSyncing else { return }
        guard !pending.isEmpty || !stale.isEmpty else { return }
        _ = enqueue {
            await self.hydrate(pending: pending, context: context)
            _ = await self.runPrices(stale: stale, context: context, force: false)
        }
    }

    /// Same as `hydrateAll`, but the caller already knows which ids are
    /// pending (CollectionStore works it out while building the snapshot), so
    /// no store round-trip is made here at all.
    private func hydrate(pending ids: [String], context: ModelContext) async {
        var seen = Set<String>()
        let queue = ids.filter { !hydrated.contains($0) && seen.insert($0).inserted }
        guard !queue.isEmpty else { return }
        await run(queue, context: context)
    }

    private func run(_ ids: [String], context: ModelContext) async {
        isSyncing = true
        syncLabel = "Syncing"
        syncTotal = ids.count
        syncedCount = 0
        let activity = DataActivity.shared
        activity.begin(.cardData, total: ids.count)
        var failed = 0

        // Keep going for a short while if the user backgrounds the app; the
        // work is idempotent, so whatever doesn't finish resumes on next open.
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "card-sync")
        defer {
            isSyncing = false
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            let done = syncedCount
            activity.end(.cardData, count: done - failed,
                         note: done < syncTotal ? "Stopped at \(done.formatted()) of \(syncTotal.formatted()) cards"
                            : failed > 0 ? "\((done - failed).formatted()) cards, \(failed.formatted()) failed"
                            : "\(done.formatted()) cards",
                         failed: failed > 0 && failed == done)
        }

        // Each batch is claimed in `inFlight` only as it goes out, and is
        // the next ids no one has fetched or claimed: the tiles on screen
        // ask through `hydrate(scryfallIDs:)`, and their window goes out
        // ahead of the rest of this run instead of waiting its turn. The
        // whole run used to be claimed up front, so the viewport top-up
        // was a no-op and, after an import, the tiles on screen filled at
        // a random point of a fifty-batch run (the ids came from a Set).
        var cursor = 0
        while cursor < ids.count {
            if Task.isCancelled { return }
            var chunk: [String] = []
            while cursor < ids.count, chunk.count < ScryfallClient.collectionBatchSize {
                let id = ids[cursor]
                cursor += 1
                if !hydrated.contains(id), !inFlight.contains(id) { chunk.append(id) }
            }
            if !chunk.isEmpty {
                inFlight.formUnion(chunk)
                do {
                    let response = try await client.collection(ids: chunk)
                    await apply(cards: response.data, context: context)
                    // Ids Scryfall doesn't know: marked so they rest a day
                    // rather than going out again on every launch.
                    let missing = Set(response.notFound?.compactMap(\.id) ?? [])
                    if !missing.isEmpty {
                        try? await writer(context).markFailed(missing, notFound: true)
                        failed += missing.count
                    }
                    hydrated.formUnion(chunk)
                } catch {
                    try? await writer(context).markFailed(Set(chunk))
                    failed += chunk.count
                }
                inFlight.subtract(chunk)
            }
            syncedCount = cursor
            activity.progress(.cardData, done: syncedCount)
        }
    }

    /// Re-fetches prices for ids the caller already knows are stale (the store
    /// computes them alongside the snapshot). Card metadata is effectively
    /// immutable, so this exists separately: only the money moves. Queued
    /// as the owned run (see `enqueue`); returns how many cards came back.
    @discardableResult
    func refreshPrices(stale ids: [String], context: ModelContext, force: Bool = false) async -> Int {
        await enqueue { await self.runPrices(stale: ids, context: context, force: force) }.value
    }

    private func runPrices(stale ids: [String], context: ModelContext, force: Bool) async -> Int {
        let stale = Array(Set(ids))
        guard !stale.isEmpty else { return 0 }
        // Settings can keep the price refresh off cellular; a manual
        // refresh from Settings passes `force`.
        let activity = DataActivity.shared
        guard force || AppSettings.pricesOnCellular || !NetworkMonitor.shared.isMetered else {
            activity.skip(.prices, note: "Waiting for Wi-Fi: \(stale.count.formatted()) cards due")
            return 0
        }

        isSyncing = true
        syncLabel = "Prices"
        syncTotal = stale.count
        syncedCount = 0
        activity.begin(.prices, total: stale.count)
        let assertion = UIApplication.shared.beginBackgroundTask(withName: "price-refresh")
        var updated = 0
        defer {
            isSyncing = false
            if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) }
            activity.end(.prices, count: updated,
                         note: syncedCount < syncTotal ? "Stopped at \(syncedCount.formatted()) of \(syncTotal.formatted()) cards"
                            : "\(updated.formatted()) cards",
                         failed: updated == 0)
        }

        for chunk in stale.chunked(into: ScryfallClient.collectionBatchSize) {
            if Task.isCancelled { return updated }
            if let response = try? await client.collection(ids: chunk) {
                await apply(cards: response.data, context: context)
                updated += response.data.count
            }
            syncedCount += chunk.count
            activity.progress(.prices, done: syncedCount)
        }
        return updated
    }

    /// Hydrates any of `scryfallIDs` whose CardMeta is still pending/failed.
    /// What a snapshot already has metadata for: a grid hands this in on
    /// load so its viewport top-ups skip the writer. Without it every row
    /// of tiles on a fully hydrated collection started a Task and an `IN`
    /// fetch of CardMeta on the writer, to learn nothing was needed.
    func markHydrated<S: Sequence>(_ scryfallIDs: S) where S.Element == String {
        hydrated.formUnion(scryfallIDs)
    }

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
                let missing = needed.subtracting(cards.map(\.id))
                if !missing.isEmpty { try? await writer(context).markFailed(missing, notFound: true) }
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
