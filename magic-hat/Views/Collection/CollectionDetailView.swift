//
//  CollectionDetailView.swift
//  magic-hat
//
//  Lists the binders inside one collection. Tapping a binder opens its card
//  grid. Binder aggregation is memoized and recomputed only when the
//  collection's entries change.
//

import SwiftUI
import SwiftData

private struct BinderSummary: Identifiable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    var id: String { name }
}

struct CollectionDetailView: View {
    let collectionName: String

    @Query private var entries: [CollectionEntry]
    @State private var binders: [BinderSummary] = []

    init(collectionName: String) {
        self.collectionName = collectionName
        var descriptor = FetchDescriptor<CollectionEntry>(
            predicate: #Predicate { $0.collectionName == collectionName },
            sortBy: [SortDescriptor(\.binderName)]
        )
        descriptor.propertiesToFetch = [\.binderName, \.quantity]
        _entries = Query(descriptor)
    }

    private func rebuildBinders() {
        let grouped = Dictionary(grouping: entries, by: \.binderName)
        binders = grouped.map { name, rows in
            BinderSummary(
                name: name,
                uniqueCards: rows.count,
                totalCopies: rows.reduce(0) { $0 + $1.quantity }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            if binders.isEmpty {
                ContentUnavailableView {
                    Text("📭").font(.system(size: 64))
                } description: {
                    Text("This collection has no cards.")
                }
            } else {
                List(binders) { binder in
                    NavigationLink {
                        BinderDetailView(collectionName: collectionName, binderName: binder.name)
                    } label: {
                        HStack {
                            Image(systemName: "books.vertical.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(binder.name)
                                    .font(.body.weight(.medium))
                                Text("\(binder.uniqueCards) cards · \(binder.totalCopies) copies")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(collectionName)
        .onChange(of: entries, initial: true) { _, _ in rebuildBinders() }
    }
}
