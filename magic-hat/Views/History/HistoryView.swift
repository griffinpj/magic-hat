//
//  HistoryView.swift
//  magic-hat
//
//  Shows the append-only audit ledger grouped by action, so each import or
//  manual change appears as one row summarising copies added/removed. This
//  is the surface that will later back undo/redo.
//
//  No @Query: the ledger is a large table, and a query over it re-ran on
//  the main thread after every background save (each hydration batch).
//  CollectionStore groups it off-main; the view refetches when a write
//  bumps the tracker.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var groups: [HistoryAction] = []
    @State private var hasLoaded = false
    private var tracker: CollectionChangeTracker { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if !hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if groups.isEmpty {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Imports and changes to your collection appear here.")
                    )
                } else {
                    List(groups) { group in
                        HistoryRow(group: group)
                    }
                }
            }
            .navigationTitle("History")
            .task(id: tracker.revision) {
                let store = CollectionStore.shared(for: modelContext.container)
                if let fetched = try? await store.history(), !Task.isCancelled {
                    groups = fetched
                }
                hasLoaded = true
            }
        }
    }
}

private struct HistoryRow: View {
    let group: HistoryAction

    private var icon: String {
        switch group.action {
        case .deckBuild, .deckDisassemble: return "rectangle.stack"
        default: return "square.and.arrow.down"
        }
    }

    private var title: String {
        switch group.action {
        case .importAdd, .importReplace: return "Import"
        case .manualAdd: return "Added Cards"
        case .manualRemove: return "Removed Cards"
        case .deckBuild: return "Built Deck"
        case .deckDisassemble: return "Disassembled Deck"
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(group.scopes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(group.timestamp, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if group.added > 0 {
                    Text("+\(group.added)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if group.removed > 0 {
                    Text("−\(group.removed)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
