//
//  CollectionView.swift
//  magic-hat
//
//  Collection tab landing screen: lists the binders in the collection and
//  hosts the "…" menu whose Import action launches the import wizard.
//

import SwiftUI
import SwiftData

/// Aggregated view of one binder for the list.
private struct BinderSummary: Identifiable {
    let name: String
    let uniqueCards: Int
    let totalCopies: Int
    var id: String { name }
}

struct CollectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CollectionEntry.binderName) private var entries: [CollectionEntry]

    @State private var showingImporter = false

    private var binders: [BinderSummary] {
        let grouped = Dictionary(grouping: entries, by: \.binderName)
        return grouped.map { name, rows in
            BinderSummary(
                name: name,
                uniqueCards: rows.count,
                totalCopies: rows.reduce(0) { $0 + $1.quantity }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if binders.isEmpty {
                    ContentUnavailableView {
                        Label("No Cards Yet", systemImage: "square.grid.3x3")
                    } description: {
                        Text("Import a ManaBox collection to get started.")
                    } actions: {
                        Button("Import Collection") { showingImporter = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    binderList
                }
            }
            .navigationTitle("Collection")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Import…", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showingImporter) {
                ImportWizardView()
            }
        }
    }

    private var binderList: some View {
        List(binders) { binder in
            NavigationLink {
                BinderDetailView(binderName: binder.name)
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

#Preview {
    CollectionView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
