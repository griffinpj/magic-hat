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

    @State private var hydrator = CardHydrationController()
    @State private var items: [CardItem] = []
    @State private var sort: CardSort = .name

    /// How many cards ahead of the visible tile to prefetch.
    private let lookahead = 30

    init(collectionName: String) {
        self.collectionName = collectionName
        _entries = Query(
            filter: #Predicate<CollectionEntry> { $0.collectionName == collectionName },
            sort: \CollectionEntry.name
        )
    }

    private func rebuildItems() {
        let metaByID = Dictionary(allMeta.map { ($0.scryfallID, $0) }) { a, _ in a }
        let built = entries.map { CardItem(entry: $0, meta: metaByID[$0.scryfallID]) }
        items = Self.sorted(built, by: sort)
    }

    private static func sorted(_ items: [CardItem], by sort: CardSort) -> [CardItem] {
        switch sort {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .setCode:
            return items.sorted {
                ($0.setCode, $0.name) < ($1.setCode, $1.name)
            }
        case .rarity:
            let order = ["common": 0, "uncommon": 1, "rare": 2, "mythic": 3, "special": 4, "bonus": 5]
            return items.sorted { (order[$0.rarity, default: -1], $0.name) > (order[$1.rarity, default: -1], $1.name) }
        case .priceHigh:
            return items.sorted { ($0.marketPrice ?? -1) > ($1.marketPrice ?? -1) }
        case .quantity:
            return items.sorted { $0.quantity > $1.quantity }
        case .recent:
            return items.sorted { ($0.addedDate ?? .distantPast) > ($1.addedDate ?? .distantPast) }
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
                    accessory: { sortButton }
                )
            }
        }
        .navigationTitle(collectionName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: entries, initial: true) { _, _ in rebuildItems() }
        .onChange(of: allMeta) { _, _ in rebuildItems() }
        .onChange(of: sort) { _, _ in
            items = Self.sorted(items, by: sort)
        }
        .task { prefetch(around: 0) }
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
