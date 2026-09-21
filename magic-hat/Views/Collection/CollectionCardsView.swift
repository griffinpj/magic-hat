//
//  CollectionCardsView.swift
//  magic-hat
//
//  Every card in one collection, in the reusable CardGridView. The view holds
//  no @Query: it asks CollectionStore for a value snapshot off the main
//  actor, so the navigation push animates while the fetch runs. It refetches
//  when a write bumps CollectionChangeTracker, and (debounced) as hydration
//  fills in metadata — without reordering mid-sync, so the grid doesn't
//  reshuffle under the user's thumb.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collectionName: String

    @Environment(\.modelContext) private var modelContext

    private var hydrator: CardHydrationController { .shared }
    private var tracker: CollectionChangeTracker { .shared }

    @State private var items: [CardItem] = []
    @State private var hasLoaded = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var sortTask: Task<Void, Never>?
    @State private var scrollToTop = 0

    /// Remembered across launches and collections.
    @AppStorage("collection.sort") private var sortRaw: String = CardSort.name.rawValue
    private var sort: CardSort { CardSort(rawValue: sortRaw) ?? .name }

    /// How many cards ahead of the visible tile to prefetch.
    private let lookahead = 30

    var body: some View {
        Group {
            if !hasLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView {
                    Text("📭").font(.system(size: 64))
                } description: {
                    Text("This collection has no cards.")
                }
            } else {
                CardGridView(
                    items: items,
                    onAppearIndex: { prefetch(around: $0) },
                    scrollToTop: scrollToTop,
                    accessory: {
                        VStack(alignment: .trailing, spacing: 10) {
                            if hydrator.isSyncing { syncPill }
                            sortButton
                        }
                    }
                )
            }
        }
        .navigationTitle(collectionName)
        .navigationBarTitleDisplayMode(.inline)
        // Initial load, and again after any write (import/delete).
        .task(id: "\(collectionName)|\(tracker.revision)") {
            await load(thenSync: true)
        }
        // Metadata arriving: refresh fields in place, keep the order.
        .onChange(of: hydrator.revision) { _, _ in scheduleRefresh() }
        .onChange(of: sortRaw) { _, _ in applySort() }
    }

    // MARK: Loading

    private var store: CollectionStore { CollectionStore.shared(for: modelContext.container) }

    /// Fetches the snapshot off-main. On the first load of a session also
    /// kicks off metadata hydration for anything pending and a price refresh
    /// for anything stale — both from ids the store already computed, so no
    /// extra store round-trips on the main thread.
    private func load(thenSync: Bool) async {
        let snapshot = (try? await store.snapshot(collectionName: collectionName, sort: sort)) ?? .empty
        guard !Task.isCancelled else { return }
        items = snapshot.items
        hasLoaded = true
        prefetch(around: 0)

        guard thenSync, !snapshot.items.isEmpty else { return }
        await hydrator.hydrate(pending: snapshot.pendingIDs, context: modelContext)
        await hydrator.refreshPrices(stale: snapshot.stalePriceIDs, context: modelContext)
        guard !Task.isCancelled else { return }
        // Sync finished: now a full re-sort is welcome (prices/rarity landed).
        if let fresh = try? await store.snapshot(collectionName: collectionName, sort: sort) {
            items = fresh.items
        }
    }

    /// Jump to the top first, then re-sort one frame later. With precomputed
    /// keys the sort itself is a few milliseconds, so it runs on the main
    /// actor with no async hop; the one-frame gap lets the grid reset to the
    /// top before the reorder lands, so LazyVGrid lays out the first screen
    /// rather than re-laying out a reordered grid deep into the old order.
    private func applySort() {
        sortTask?.cancel()
        scrollToTop &+= 1
        sortTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            items = CardSorting.sorted(items, by: sort)
        }
    }

    /// Debounced refresh during hydration. Longer while a full sync is
    /// running (a save lands every ~500ms) so we don't refetch on each one.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        let delay: Duration = hydrator.isSyncing ? .milliseconds(1500) : .milliseconds(300)
        refreshTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await refreshInPlace()
        }
    }

    /// Pulls fresh fields for the items we have, preserving current order.
    private func refreshInPlace() async {
        guard let fresh = try? await store.snapshot(collectionName: collectionName, sort: sort),
              !Task.isCancelled else { return }
        let byID = Dictionary(fresh.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var next: [CardItem] = []
        next.reserveCapacity(fresh.items.count)
        for item in items {
            if let updated = byID[item.id] { next.append(updated); seen.insert(item.id) }
        }
        for item in fresh.items where !seen.contains(item.id) { next.append(item) }
        items = next
    }

    /// Viewport lookahead: metadata for the next window of tiles.
    private func prefetch(around index: Int) {
        guard !items.isEmpty, index < items.count else { return }
        let upper = min(index + lookahead, items.count)
        let window = items[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }

    // MARK: Accessories

    private var syncPill: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Syncing \(hydrator.syncedCount)/\(hydrator.syncTotal)")
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.trailing, 20)
    }

    private var sortButton: some View {
        Menu {
            // Plain buttons, not a Picker: a Picker inside a Menu builds a
            // nested selection control and is noticeably slower to present.
            ForEach(CardSort.allCases) { option in
                Button {
                    sortRaw = option.rawValue
                } label: {
                    Label(option.rawValue, systemImage: option == sort ? "checkmark" : option.systemImage)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("sort-button")
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
}
