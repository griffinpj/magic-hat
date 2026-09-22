//
//  SearchView.swift
//  magic-hat
//
//  The Search tab. A native searchable NavigationStack over a
//  SearchController; results go straight into the shared CardGridView, so
//  a search hit gets the same tile, viewer, detail screen and actions as a
//  card in a collection.
//
//  The pieces are deliberately separable: SearchController holds the
//  query/results, SearchFiltersView edits a CardSearchQuery binding, and
//  the grid takes [CardItem]. A later screen that wants search at the top
//  composes the same three; nothing here is specific to being a tab.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedSearch.sortOrder) private var savedSearches: [SavedSearch]

    @State private var controller = SearchController()
    @State private var showFilters = false
    @State private var showSavedList = false
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @State private var suggestions: [String] = []
    @State private var suggestionTask: Task<Void, Never>?

    private var tracker: CollectionChangeTracker { .shared }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(text: $controller.query.text, prompt: "Cards, types, rules text")
                .searchSuggestions { suggestionRows }
                .onSubmit(of: .search) { controller.run() }
                .onChange(of: controller.query.text) { _, text in textChanged(text) }
                .toolbar { toolbar }
                .sheet(isPresented: $showFilters, onDismiss: { controller.runIfChanged() }) {
                    SearchFiltersView(query: $controller.query)
                }
                .navigationDestination(isPresented: $showSavedList) {
                    SavedSearchesView(onSelect: load)
                }
                .alert("Save Search", isPresented: $showSaveAlert) {
                    TextField("Name", text: $saveName)
                    Button("Save") { saveCurrent() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(controller.query.summary)
                }
                .task(id: tracker.revision) { await refreshOwned() }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle:
            idle
        case .searching:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            results
        case .empty:
            ContentUnavailableView {
                Label("No Cards", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing on Scryfall matches this search.")
            } actions: {
                if controller.query.hasFilters {
                    Button("Adjust Filters") { showFilters = true }
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Search Failed", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { controller.run() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Before a search: saved searches to jump into, or a hint.
    @ViewBuilder private var idle: some View {
        if savedSearches.isEmpty {
            ContentUnavailableView(
                "Search Scryfall",
                systemImage: "magnifyingglass",
                description: Text("Find any Magic card by name, type, rules text, color, format, set, price and more. Filters make it precise; save a search to come back to it.")
            )
        } else {
            List {
                Section("Saved Searches") {
                    ForEach(savedSearches) { saved in
                        Button { load(saved) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(saved.name).foregroundStyle(.primary)
                                Text(saved.query.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            resultsHeader
            CardGridView(items: controller.results, onAppearIndex: { controller.loadMore(near: $0) })
        }
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            if let total = controller.totalCards {
                Text("\(total.formatted()) \(total == 1 ? "card" : "cards")")
            } else {
                Text("\(controller.results.count.formatted())+ cards")
            }
            if let applied = controller.appliedQuery, applied.hasFilters {
                Text("·")
                Text("\(applied.activeFilterCount) \(applied.activeFilterCount == 1 ? "filter" : "filters")")
            }
            Spacer()
            if controller.isLoadingMore {
                ProgressView().controlSize(.small)
            }
            Text(controller.query.sort.label)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    // MARK: Suggestions

    @ViewBuilder private var suggestionRows: some View {
        ForEach(suggestions, id: \.self) { name in
            Text(name).searchCompletion(name)
        }
    }

    private func textChanged(_ text: String) {
        // Clearing the field (the ✕, or Cancel) with no filters returns to
        // the start; with filters the results stand until the next submit.
        if text.isEmpty, !controller.query.hasFilters, controller.phase != .idle {
            controller.clear()
        }
        scheduleSuggestions(text)
    }

    /// Name completions from /cards/autocomplete, debounced, skipped for
    /// anything that looks like Scryfall syntax.
    private func scheduleSuggestions(_ text: String) {
        suggestionTask?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, !t.contains(":") else { suggestions = []; return }
        suggestionTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let names = (try? await ScryfallClient.shared.autocomplete(t)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = names
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Save Search…", systemImage: "bookmark.badge.plus") {
                    saveName = controller.query.suggestedName
                    showSaveAlert = true
                }
                .disabled(controller.query.isEmpty)
                if !savedSearches.isEmpty {
                    Divider()
                    ForEach(savedSearches) { saved in
                        Button(saved.name, systemImage: "bookmark") { load(saved) }
                    }
                    Divider()
                    Button("Edit Saved Searches…", systemImage: "pencil") { showSavedList = true }
                }
            } label: {
                Label("Saved Searches", systemImage: "bookmark")
            }
            .accessibilityIdentifier("search-saved")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                ForEach(SearchSort.allCases) { option in
                    Button {
                        controller.query.sort = option
                        controller.query.direction = nil
                        rerun()
                    } label: {
                        Label(option.label, systemImage: option == controller.query.sort ? "checkmark" : option.systemImage)
                    }
                }
                Divider()
                let current = controller.query.effectiveDirection
                Button {
                    controller.query.direction = current == .ascending ? .descending : .ascending
                    rerun()
                } label: {
                    Label(current == .ascending ? "Ascending" : "Descending",
                          systemImage: current == .ascending ? "arrow.up" : "arrow.down")
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("search-sort")

            Button {
                showFilters = true
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                    .symbolVariant(controller.query.hasFilters ? .circle.fill : .circle)
            }
            .accessibilityIdentifier("search-filters")
            .accessibilityValue(controller.query.hasFilters ? "\(controller.query.activeFilterCount) active" : "none")
        }
    }

    // MARK: Actions

    /// Sort changes re-run only once there is something on screen.
    private func rerun() {
        if controller.appliedQuery != nil { controller.run() }
    }

    private func load(_ saved: SavedSearch) {
        saved.lastUsedDate = Date()
        controller.query = saved.query
        controller.run()
    }

    private func saveCurrent() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let order = (savedSearches.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(SavedSearch(name: name, query: controller.query, sortOrder: order))
        try? modelContext.save()
    }

    private func refreshOwned() async {
        let store = CollectionStore.shared(for: modelContext.container)
        guard let ids = try? await store.ownedScryfallIDs(), !Task.isCancelled else { return }
        controller.updateOwned(ids)
    }
}

#Preview {
    SearchView()
        .modelContainer(for: [SavedSearch.self, CollectionEntry.self, CardMeta.self], inMemory: true)
}
