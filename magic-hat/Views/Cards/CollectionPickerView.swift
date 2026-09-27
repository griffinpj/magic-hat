//
//  CollectionPickerView.swift
//  magic-hat
//
//  Pushed from the Add sheet: choose a destination collection. Same cards as
//  the Collections tab (minus the value), searchable, with a "+" that
//  creates an empty collection through a native alert — no wizard.
//

import SwiftUI
import SwiftData

struct CollectionPickerView: View {
    @Binding var selected: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var summaries: [CollectionSummary] = []
    @State private var search = ""
    /// The kind the name alert creates; kept after it closes, since the
    /// alert's button runs as it dismisses.
    @State private var creatingKind: CollectionKind = .collection
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var createError: String?

    private var store: CollectionStore { .shared(for: modelContext.container) }

    private var filtered: [CollectionSummary] {
        guard !search.isEmpty else { return summaries }
        return summaries.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ForEach(filtered.filter { !$0.isList }) { row($0) }
            let lists = filtered.filter(\.isList)
            if !lists.isEmpty {
                Text("Lists")
                    .font(.headline)
                    .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityAddTraits(.isHeader)
                ForEach(lists) { row($0) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if summaries.isEmpty {
                ContentUnavailableView("No Collections", systemImage: "tray",
                                       description: Text("Create one with the + button."))
            }
        }
        .navigationTitle("Collection")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search collections")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Collection", systemImage: CollectionKind.collection.systemImage) { startCreate(.collection) }
                        .accessibilityIdentifier("new-collection")
                    Button("New List", systemImage: CollectionKind.list.systemImage) { startCreate(.list) }
                        .accessibilityIdentifier("new-list")
                } label: {
                    Label("New", systemImage: "plus")
                }
                .accessibilityIdentifier("new-collection-or-list")
            }
        }
        .alert(creatingKind == .list ? "New List" : "New Collection", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(creatingKind == .list ? "Cards you want rather than own. They don't count toward your collection." : "An empty collection you can add cards to.")
        }
        .alert("Couldn't create", isPresented: Binding(get: { createError != nil },
                                                     set: { if !$0 { createError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
        .task(id: CollectionChangeTracker.shared.revision) {
            if let fresh = try? await store.summaries(stamp: .current) { summaries = fresh }
        }
    }

    private func row(_ summary: CollectionSummary) -> some View {
        Button {
            selected = summary.name
            dismiss()
        } label: {
            CollectionCard(summary: summary, name: summary.name, showsValue: false, isList: summary.isList)
                .overlay(alignment: .topTrailing) {
                    if summary.name == selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .padding(12)
                    }
                }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier("pick-collection-\(summary.name)")
    }

    private func startCreate(_ kind: CollectionKind) {
        newName = ""
        creatingKind = kind
        showingCreate = true
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if try CollectionEditController.createCollection(named: name, kind: creatingKind, context: modelContext) {
                selected = name
                dismiss()
            } else {
                createError = name.isEmpty ? "Give it a name." : "“\(name)” is already taken by a collection or list."
            }
        } catch {
            createError = error.localizedDescription
        }
    }
}
