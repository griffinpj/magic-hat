//
//  HistoryView.swift
//  magic-hat
//
//  Shows the append-only audit ledger grouped by action, so each import or
//  manual change appears as one row summarising copies added/removed. This
//  is the surface that will later back undo/redo.
//

import SwiftUI
import SwiftData

/// One user action, aggregated from its AuditRecords (shared actionID).
private struct ActionGroup: Identifiable {
    let actionID: UUID
    let timestamp: Date
    let added: Int
    let removed: Int
    /// Collections touched by the action. Older records also carry a source
    /// binder name; it is folded in here so pre-migration history still reads.
    let scopes: [String]
    let action: AuditAction
    var id: UUID { actionID }
}

struct HistoryView: View {
    @Query(sort: \AuditRecord.timestamp, order: .reverse) private var records: [AuditRecord]

    private var groups: [ActionGroup] {
        let grouped = Dictionary(grouping: records, by: \.actionID)
        return grouped.values.map { recs -> ActionGroup in
            let added = recs.filter { $0.quantityDelta > 0 }.reduce(0) { $0 + $1.quantityDelta }
            let removed = recs.filter { $0.quantityDelta < 0 }.reduce(0) { $0 + $1.quantityDelta }
            var scopes = Set(recs.map(\.collectionName))
            scopes.formUnion(recs.map(\.binderName).filter { !$0.isEmpty })
            return ActionGroup(
                actionID: recs[0].actionID,
                timestamp: recs.map(\.timestamp).max() ?? .distantPast,
                added: added,
                removed: -removed,
                scopes: scopes.sorted(),
                action: recs[0].action
            )
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
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
        }
    }
}

private struct HistoryRow: View {
    let group: ActionGroup

    private var title: String {
        switch group.action {
        case .importAdd, .importReplace: return "Import"
        case .manualAdd: return "Added Cards"
        case .manualRemove: return "Removed Cards"
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "square.and.arrow.down")
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
