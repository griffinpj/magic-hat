//
//  CollectionCardsView.swift
//  magic-hat
//
//  Shows every card in one collection using the reusable CardGridView (flat:
//  binders are metadata, not a navigation level). Builds the grid's [CardItem]
//  from owned entries + cached metadata, memoized so it only rebuilds when the
//  data changes. Metadata/images are hydrated lazily as tiles approach view.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collectionName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [CollectionEntry]
    @Query private var allMeta: [CardMeta]

    @State private var hydrator = CardHydrationController()
    @State private var items: [CardItem] = []

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
        items = entries.map { CardItem(entry: $0, meta: metaByID[$0.scryfallID]) }
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
                CardGridView(items: items) { index in
                    prefetch(around: index)
                }
            }
        }
        .navigationTitle(collectionName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: entries, initial: true) { _, _ in rebuildItems() }
        .onChange(of: allMeta) { _, _ in rebuildItems() }
        .task { prefetch(around: 0) }
    }

    /// Hydrates the window of cards starting at `index` through the lookahead.
    private func prefetch(around index: Int) {
        guard !items.isEmpty else { return }
        let upper = min(index + lookahead, items.count)
        let window = items[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }
}
