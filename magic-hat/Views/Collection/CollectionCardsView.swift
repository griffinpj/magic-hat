//
//  CollectionCardsView.swift
//  magic-hat
//
//  Shows every card in one collection using the reusable CardGridView (flat:
//  binders are metadata, not a navigation level). Builds the grid's [CardItem]
//  from owned entries + cached metadata, memoized so it only rebuilds when the
//  data changes. A floating Liquid Glass sort control reorders the grid.
//

import SwiftUI
import SwiftData

enum CardSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case setCode = "Set"
    case rarity = "Rarity"
    case priceHigh = "Price (High)"
    case quantity = "Quantity"
    case recent = "Recently Added"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .setCode: return "square.stack.3d.up"
        case .rarity: return "sparkles"
        case .priceHigh: return "dollarsign.circle"
        case .quantity: return "number"
        case .recent: return "clock"
        }
    }
}

struct CollectionCardsView: View {
    let collectionName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [CollectionEntry]
    @Query private var allMeta: [CardMeta]

    private var hydrator: CardHydrationController { .shared }
    @State private var refreshTask: Task<Void, Never>?
    @State private var items: [CardItem] = []
    @State private var sort: CardSort = .name
    @State private var didStartSync = false

    /// How many cards ahead of the visible tile to prefetch.
    private let lookahead = 30

    init(collectionName: String) {
        self.collectionName = collectionName
        _entries = Query(
            filter: #Predicate<CollectionEntry> { $0.collectionName == collectionName },
            sort: \CollectionEntry.name
        )
    }

    /// Full rebuild + sort. Use on entries/sort changes only.
    private func rebuildItems() {
        let metaByID = Dictionary(allMeta.map { ($0.scryfallID, $0) }) { a, _ in a }
        let built = entries.map { CardItem(entry: $0, meta: metaByID[$0.scryfallID]) }
        items = Self.sorted(built, by: sort)
    }

    /// Refresh image/price fields as metadata hydrates WITHOUT reordering, so
    /// the grid doesn't thrash while scrolling/hydrating.
    private func refreshMeta() {
        guard !items.isEmpty else { rebuildItems(); return }
        let metaByID = Dictionary(allMeta.map { ($0.scryfallID, $0) }) { a, _ in a }
        let entryByID = Dictionary(entries.map { ($0.id.uuidString, $0) }) { a, _ in a }
        items = items.map { item in
            guard let entry = entryByID[item.id] else { return item }
            return CardItem(entry: entry, meta: metaByID[item.scryfallID])
        }
    }

    /// Coalesce the storm of metadata saves a full sync produces (one per
    /// 75-card batch) into a single rebuild, instead of remapping every
    /// CardItem dozens of times.
    private func scheduleRefreshMeta() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            refreshMeta()
        }
    }

    /// Rarity ordering, low → high. Unknown rarity sorts lowest.
    private static let rarityRank = [
        "common": 0, "uncommon": 1, "rare": 2, "mythic": 3, "special": 4, "bonus": 5
    ]

    /// Every comparator defines a TOTAL order (always falling through to name
    /// then id). Swift's sort is not stable, so without a tie-breaker the
    /// thousands of cards sharing a key — e.g. every card with no price yet —
    /// came back in arbitrary, shuffling order.
    private static func sorted(_ items: [CardItem], by sort: CardSort) -> [CardItem] {
        func byName(_ a: CardItem, _ b: CardItem) -> Bool {
            let c = a.name.localizedCaseInsensitiveCompare(b.name)
            if c != .orderedSame { return c == .orderedAscending }
            return a.id < b.id
        }
        switch sort {
        case .name:
            return items.sorted(by: byName)
        case .setCode:
            return items.sorted {
                if $0.setCode != $1.setCode { return $0.setCode < $1.setCode }
                let l = Int($0.collectorNumber) ?? Int.max
                let r = Int($1.collectorNumber) ?? Int.max
                if l != r { return l < r }
                return byName($0, $1)
            }
        case .rarity:
            return items.sorted {
                let l = rarityRank[$0.rarity.lowercased()] ?? -1
                let r = rarityRank[$1.rarity.lowercased()] ?? -1
                if l != r { return l > r }
                return byName($0, $1)
            }
        case .priceHigh:
            return items.sorted {
                // Unpriced sorts to the bottom, then alphabetically.
                let l = $0.marketPrice ?? 0
                let r = $1.marketPrice ?? 0
                if l != r { return l > r }
                return byName($0, $1)
            }
        case .quantity:
            return items.sorted {
                if $0.quantity != $1.quantity { return $0.quantity > $1.quantity }
                return byName($0, $1)
            }
        case .recent:
            return items.sorted {
                let l = $0.addedDate ?? .distantPast
                let r = $1.addedDate ?? .distantPast
                if l != r { return l > r }
                return byName($0, $1)
            }
        }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Text("📭").font(.system(size: 64))
                } description: {
                    Text("This collection has no cards.")
                }
            } else {
                CardGridView(
                    items: items,
                    onAppearIndex: { prefetch(around: $0) },
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
        .onChange(of: entries, initial: true) { _, _ in rebuildItems() }
        .onChange(of: allMeta) { _, _ in scheduleRefreshMeta() }
        .onChange(of: sort) { _, _ in
            items = Self.sorted(items, by: sort)
        }
        .task { prefetch(around: 0) }
        // Fetch metadata for the WHOLE collection once, so sorting by price or
        // rarity works on complete data rather than the handful of cards that
        // happened to scroll past.
        .task(id: entries.count) {
            guard !didStartSync, !entries.isEmpty else { return }
            didStartSync = true
            let ids = entries.map(\.scryfallID)
            await hydrator.hydrateAll(scryfallIDs: ids, context: modelContext)
            // Metadata is immutable; prices are not. Refresh only the stale ones.
            await hydrator.refreshStalePrices(scryfallIDs: ids, context: modelContext)
            refreshMeta()
            items = Self.sorted(items, by: sort)
        }
    }

    // Progress while the full-collection metadata sync runs.
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

    // Floating Liquid Glass sort control; padded to sit above the tab bar.
    private var sortButton: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(CardSort.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage).tag(option)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    /// Hydrates the window of cards starting at `index` through the lookahead.
    private func prefetch(around index: Int) {
        guard !items.isEmpty else { return }
        let upper = min(index + lookahead, items.count)
        let window = items[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }
}
