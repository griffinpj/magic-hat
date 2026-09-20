//
//  BinderDetailView.swift
//  magic-hat
//
//  A 3-wide card grid for one binder. Card metadata and images are
//  hydrated lazily as tiles approach the viewport: when a tile appears we
//  prefetch a lookahead window of cards so images are usually ready before
//  the user scrolls to them, avoiding visible loading.
//

import SwiftUI
import SwiftData

struct BinderDetailView: View {
    let binderName: String

    @Environment(\.modelContext) private var modelContext
    @Query private var entries: [CollectionEntry]
    @Query private var allMeta: [CardMeta]

    @State private var hydrator = CardHydrationService()

    /// How many cards ahead of the visible tile to prefetch.
    private let lookahead = 30

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    init(binderName: String) {
        self.binderName = binderName
        _entries = Query(
            filter: #Predicate<CollectionEntry> { $0.binderName == binderName },
            sort: \CollectionEntry.name
        )
    }

    private var metaByID: [String: CardMeta] {
        Dictionary(allMeta.map { ($0.scryfallID, $0) }) { a, _ in a }
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
        .navigationTitle(binderName)
        .navigationBarTitleDisplayMode(.inline)
        .task { prefetch(around: 0) }
    }

    /// Hydrates the window of cards starting at `index` through the lookahead.
    private func prefetch(around index: Int) {
        guard !entries.isEmpty else { return }
        let upper = min(index + lookahead, entries.count)
        let window = entries[index..<upper].map(\.scryfallID)
        hydrator.hydrate(scryfallIDs: window, context: modelContext)
    }
}
