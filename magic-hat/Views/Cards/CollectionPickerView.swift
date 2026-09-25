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
            ForEach(filtered) { summary in
                Button {
                    selected = summary.name
                    dismiss()
                } label: {
                    CollectionCard(summary: summary, name: summary.name, showsValue: false)
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
                Button { newName = ""; showingCreate = true } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .accessibilityIdentifier("new-collection")
            }
        }
        .alert("New Collection", isPresented: $showingCreate) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty collection you can add cards to.")
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

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if try CollectionEditController.createCollection(named: name, context: modelContext) {
                selected = name
                dismiss()
            } else {
                createError = name.isEmpty ? "Give it a name." : "A collection called “\(name)” already exists."
            }
        } catch {
            createError = error.localizedDescription
        }
    }
}
