//
//  CollectionCardsView.swift
//  magic-hat
//
//  A 3-wide card grid for every card in one collection (flat: binders are
//  metadata, not a navigation level). Card metadata and images are hydrated
//  lazily as tiles approach the viewport: when a tile appears we prefetch a
//  lookahead window so images are usually ready before the user scrolls to
//  them, avoiding visible loading.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collectionName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [CollectionEntry]
    @Query private var allMeta: [CardMeta]

    @State private var hydrator = CardHydrationController()
    // Memoized meta lookup, rebuilt only when metadata changes.
    @State private var metaByID: [String: CardMeta] = [:]

    /// How many cards ahead of the visible tile to prefetch.
    private let lookahead = 30

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    init(collectionName: String) {
        self.collectionName = collectionName
        _entries = Query(
            filter: #Predicate<CollectionEntry> {
                $0.collectionName == collectionName
            },
            sort: \CollectionEntry.name
        )
    }

    private func rebuildMeta() {
        metaByID = Dictionary(allMeta.map { ($0.scryfallID, $0) }) { a, _ in a }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    CardTile(entry: entry, meta: metaByID[entry.scryfallID])
                        .onAppear { prefetch(around: index) }
                }
            }
            .padding(10)
        }
        .navigationTitle(collectionName)
        .navigationBarTitleDisplayMode(.inline)
        .task { prefetch(around: 0) }
        .onChange(of: allMeta, initial: true) { _, _ in rebuildMeta() }
    }

    /// Hydrates the window of cards starting at `index` through the lookahead.
    private func prefetch(around index: Int) {
        guard !entries.isEmpty else { return }
        let upper = min(index + lookahead, entries.count)
        let window = entries[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }
}
