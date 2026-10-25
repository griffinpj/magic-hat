//
//  DeckFolderPicker.swift
//  magic-hat
//
//  Where a deck goes: the Decks tab's top level or any folder, drawn as the
//  folder tree, each a tap away, with New Folder in the bar. One sheet for
//  every "where to": moving decks or a folder (the folder it is in now
//  checked, a folder never into itself) and importing a preconstructed deck
//  (nothing checked — it is nowhere yet).
//
//  A tap carries the choice out through `onPick`; an error it throws is
//  shown and the sheet stays, otherwise the sheet closes.
//

import SwiftUI
import SwiftData

struct DeckFolderPicker: View {
    let title: String
    /// What is going there, under the title, when the title alone would
    /// truncate it ("Import To" over a precon's long name).
    var subtitle: String? = nil
    /// Where it is now, checked: `.some(nil)` is the top level; nil when it
    /// is nowhere yet.
    var current: UUID?? = nil
    /// A destination it can't go to (a folder into itself or below).
    var isBlocked: (UUID?) -> Bool = { _ in false }
    /// The new-folder alert's action: "Create and Move", "Create and Import".
    let createLabel: String
    let onPick: (UUID?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DeckFolder.name) private var folders: [DeckFolder]
    @State private var error: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    private var tree: DeckFolderTree { DeckFolderTree(folders) }

    var body: some View {
        NavigationStack {
            List {
                destination(nil, name: "Decks", depth: 0)
                ForEach(tree.flattened(), id: \.node.id) { entry in
                    destination(entry.node.id, name: entry.node.name, depth: entry.depth + 1)
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showNewFolder = true
                    }
                }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Name", text: $newFolderName)
                Button(createLabel) { createAndPick() }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Do That", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .presentationDetents([.medium, .large])
    }

    private func destination(_ id: UUID?, name: String, depth: Int) -> some View {
        let blocked = isBlocked(id)
        return Button {
            pick(id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: id == nil ? "rectangle.stack.fill" : "folder.fill")
                    .foregroundStyle(blocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                Text(name).foregroundStyle(blocked ? .secondary : .primary)
                Spacer()
                if let current, id == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.leading, CGFloat(depth) * 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .accessibilityIdentifier("move-to-\(name)")
    }

    private func pick(_ id: UUID?) {
        do {
            try onPick(id)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createAndPick() {
        do {
            let folder = try DeckEditController.createFolder(named: newFolderName, in: nil, context: modelContext)
            pick(folder.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
