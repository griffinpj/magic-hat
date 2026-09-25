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
//  The collection is treated as a search that is always active: a search
//  field and a Filters button (the same CardSearchQuery and filter sheet as
//  the Search tab), evaluated in memory against this collection's cards —
//  never Scryfall. Filtering runs off the main actor and keeps the grid's
//  order.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collectionName: String

    @Environment(\.modelContext) private var modelContext

    private var hydrator: CardHydrationController { .shared }
    private var tracker: CollectionChangeTracker { .shared }

    /// Every card, in the current sort. A stamped list, not an array: a
    /// `@State` array is copied into the view value and compared card by
    /// card by the parent on each of *its* updates — 1.68s mid-sync with
    /// the real collection (see CardItemList).
    @State private var items = CardItemList()
    @State private var hasLoaded = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var sortTask: Task<Void, Never>?
    @State private var scrollToTop = 0

    /// What's being searched for within this collection. Text and filters
    /// narrow `items` to `visible`; the empty query shows everything.
    @State private var query = CardSearchQuery()
    /// What the grid shows: stamped, so handing it to the grid costs one
    /// compare, not one per card (see CardItemList).
    @State private var visible = CardItemList()
    @State private var filterTask: Task<Void, Never>?
    @State private var showFilters = false

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
            } else if visible.isEmpty, !query.isEmpty {
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing in \(CollectionScope.displayName(collectionName)) matches this search.")
                } actions: {
                    if query.hasFilters {
                        Button("Adjust Filters") { showFilters = true }
                    }
                    Button("Clear Search") { query = CardSearchQuery() }
                }
            } else {
                CardGridView(
                    items: visible,
                    onAppearIndex: { prefetch(around: $0) },
                    scrollToTop: scrollToTop,
                    accessory: {
                        VStack(alignment: .trailing, spacing: 10) {
                            SyncPill()
                            sortButton
                        }
                    }
                )
            }
        }
        .background {
            SearchDismisser(isEmpty: query.text.isEmpty)
            // Metadata arriving: refresh fields in place, keep the order.
            // Observed down here rather than with onChange on this view:
            // reading `revision` in this body re-rendered the screen, and
            // with it the grid, on every hydration batch.
            HydrationObserver { scheduleRefresh() }
        }
        .navigationTitle(CollectionScope.displayName(collectionName))
        .navigationBarTitleDisplayMode(.inline)
        // Always shown: a pushed screen with an inline title otherwise hides
        // the field until the user pulls down, and this screen *is* a search.
        .searchable(text: $query.text, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search this collection")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease")
                        .symbolVariant(query.hasFilters ? .circle.fill : .circle)
                        .foregroundStyle(query.hasFilters ? Color.accentColor : Color.primary)
                }
                .accessibilityIdentifier("collection-filters")
                .accessibilityValue(query.hasFilters ? "\(query.activeFilterCount) active" : "none")
                // The field's own Cancel clears text; this one is for the
                // filters, which nothing else clears in one tap.
                if query.hasFilters {
                    Button("Clear Search", systemImage: "xmark") { query = CardSearchQuery() }
                        .accessibilityIdentifier("collection-clear")
                }
            }
        }
        .sheet(isPresented: $showFilters) {
            SearchFiltersView(query: $query, context: .collection)
        }
        .onChange(of: query) { _, _ in applyFilter() }
        // Initial load, and again after any write (import/delete).
        .task(id: "\(collectionName)|\(tracker.revision)") {
            await load(thenSync: true)
        }
        .onChange(of: sortRaw) { _, _ in applySort() }
    }

    // MARK: Loading

    private var store: CollectionStore { CollectionStore.shared(for: modelContext.container) }

    /// Fetches the snapshot off-main. On the first load of a session also
    /// kicks off metadata hydration for anything pending and a price refresh
    /// for anything stale — both from ids the store already computed, so no
    /// extra store round-trips on the main thread.
    private func load(thenSync: Bool) async {
        let snapshot = (try? await store.snapshot(collectionName: collectionName, sort: sort, stamp: .current)) ?? .empty
        guard !Task.isCancelled else { return }
        items = CardItemList(snapshot.items)
        applyFilter()
        hasLoaded = true
        prefetch(around: 0)

        guard thenSync, !snapshot.items.isEmpty else { return }
        await hydrator.hydrate(pending: snapshot.pendingIDs, context: modelContext)
        await hydrator.refreshPrices(stale: snapshot.stalePriceIDs, context: modelContext)
        guard !Task.isCancelled else { return }
        // Sync finished: now a full re-sort is welcome (prices/rarity landed).
        if let fresh = try? await store.snapshot(collectionName: collectionName, sort: sort, stamp: .current) {
            items = CardItemList(fresh.items)
            applyFilter()
        }
    }

    /// Jump to the top first, then re-sort one frame later: the gap lets
    /// the grid reset to the top before the reorder lands, so LazyVGrid
    /// lays out the first screen rather than re-laying out a reordered
    /// grid deep into the old order. The sort itself runs off the main
    /// actor — a few milliseconds in a release build, tens in a debug one,
    /// and either way not the main thread's to spend.
    private func applySort() {
        sortTask?.cancel()
        scrollToTop &+= 1
        let sort = self.sort
        let all = items.items
        sortTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            let sorted = await Task.detached(priority: .userInitiated) { CardItemList(CardSorting.sorted(all, by: sort)) }.value
            guard !Task.isCancelled else { return }
            items = sorted
            applyFilter()
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
    /// The merge (a dictionary of every card, then a pass over the order)
    /// runs off the main actor; only the assignment lands there.
    private func refreshInPlace() async {
        guard let fresh = try? await store.snapshot(collectionName: collectionName, sort: sort, stamp: .current),
              !Task.isCancelled else { return }
        let current = items.items
        let next = await Task.detached(priority: .userInitiated) { () -> CardItemList in
            let byID = Dictionary(fresh.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var seen = Set<String>()
            var next: [CardItem] = []
            next.reserveCapacity(fresh.items.count)
            for item in current {
                if let updated = byID[item.id] { next.append(updated); seen.insert(item.id) }
            }
            for item in fresh.items where !seen.contains(item.id) { next.append(item) }
            return CardItemList(next)
        }.value
        guard !Task.isCancelled else { return }
        items = next
        applyFilter()
    }

    /// Viewport lookahead: metadata for the next window of tiles.
    private func prefetch(around index: Int) {
        guard !visible.isEmpty, index < visible.count else { return }
        let upper = min(index + lookahead, visible.count)
        let window = visible.items[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }

    // MARK: Search within the collection

    /// Narrows `items` to `visible` off the main actor, keeping order. A
    /// short pause absorbs a burst of keystrokes; a newer call cancels an
    /// older filter still running. Called wherever `items` is assigned
    /// rather than from onChange(of: items) — comparing two 4k-item arrays
    /// on every hydration refresh is itself main-thread work.
    private func applyFilter() {
        filterTask?.cancel()
        let q = query
        let all = items
        guard !q.isEmpty else { visible = all; return }
        filterTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let result = CardItemList(all.items.filter { q.matches($0) })
            guard !Task.isCancelled else { return }
            await MainActor.run { visible = result }
        }
    }

    // MARK: Accessories


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

/// "Syncing n/N" while hydration runs. Its own view so the count, which
/// moves every batch, is read in this body alone — read in the grid's
/// accessory closure it made the whole grid a dependent of the counter.
private struct SyncPill: View {
    private var hydrator: CardHydrationController { .shared }

    var body: some View {
        if hydrator.isSyncing {
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
    }
}
