//
//  SavedSearchesView.swift
//  magic-hat
//
//  Manage saved searches: run one, rename, reorder, delete. A plain
//  editable List — swipe to delete, Edit for reordering, a context menu
//  and an alert for renaming.
//

import SwiftUI
import SwiftData

struct SavedSearchesView: View {
    let onSelect: (SavedSearch) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedSearch.sortOrder) private var saved: [SavedSearch]

    @State private var renaming: SavedSearch?
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(saved) { search in
                Button {
                    onSelect(search)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(search.name).foregroundStyle(.primary)
                        Text(search.query.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        newName = search.name
                        renaming = search
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(search) }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(search) }
                    Button("Rename", systemImage: "pencil") {
                        newName = search.name
                        renaming = search
                    }
                    .tint(.orange)
                }
            }
            .onMove(perform: move)
            .onDelete { offsets in offsets.map { saved[$0] }.forEach(delete) }
        }
        .overlay {
            if saved.isEmpty {
                ContentUnavailableView(
                    "No Saved Searches",
                    systemImage: "bookmark",
                    description: Text("Save a search from the bookmark menu to find it here.")
                )
            }
        }
        .navigationTitle("Saved Searches")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if !saved.isEmpty { EditButton() } }
        .alert("Rename Search", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { search in
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { search.name = name; try? modelContext.save() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            EmptyView()
        }
    }

    private func delete(_ search: SavedSearch) {
        modelContext.delete(search)
        try? modelContext.save()
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = saved
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, s) in ordered.enumerated() where s.sortOrder != i { s.sortOrder = i }
        try? modelContext.save()
    }
}
