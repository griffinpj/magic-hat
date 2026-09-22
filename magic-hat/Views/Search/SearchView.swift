//
//  SearchView.swift
//  magic-hat
//
//  The Search tab. Two states of one screen:
//
//  - Nothing searched yet: the filters *are* the page — a Form with saved
//    searches at the top and every filter inline, plus a Search button in
//    the bottom bar. Typing in the search field runs live (debounced), so
//    the first results appear as you type.
//  - Results: the shared CardGridView. Filters move behind the toolbar
//    icon (the same sections, in a sheet over a draft) so a search can be
//    refined without leaving it. Clearing the field returns to the form.
//
//  Name completions from Scryfall show as a chip strip above the results
//  rather than a list that would hide them — the live grid already answers
//  "what matches", the strip answers "did you mean this exact card".
//
//  The pieces are deliberately separable: SearchController holds the
//  query/results, SearchFilterSections edits a CardSearchQuery binding, and
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
    @State private var completions: [String] = []
    @State private var completionTask: Task<Void, Never>?
    @FocusState private var focusedField: FilterField?

    private var tracker: CollectionChangeTracker { .shared }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(text: $controller.query.text, prompt: "Card name, type, rules text")
                // Live results are refined *while* the field is active, so
                // the title and the Sort/Filters items must stay; by default
                // an active search hides them and only Cancel remains.
                .searchPresentationToolbarBehavior(.avoidHidingContent)
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
            landing
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

    /// Before a search: saved searches, then every filter inline.
    private var landing: some View {
        Form {
            if !savedSearches.isEmpty {
                Section {
                    ForEach(savedSearches) { saved in
                        Button { load(saved) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bookmark.fill").foregroundStyle(.tint)
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
                } header: {
                    Text("Saved Searches")
                }
            }
            SearchFilterSections(query: $controller.query, focused: $focusedField)
            Section {
                Button("Reset Filters", role: .destructive) { controller.query.clearFilters() }
                    .frame(maxWidth: .infinity)
                    .disabled(!controller.query.hasFilters)
                    .accessibilityIdentifier("filters-reset")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .filterKeyboardBar($focusedField)
        // The one action on this screen, floating above the tab bar. A
        // .bottomBar toolbar item is drawn *under* the iOS 26 tab bar here.
        .safeAreaInset(edge: .bottom) {
            Button {
                focusedField = nil
                controller.run()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .disabled(controller.query.isEmpty)
            .accessibilityIdentifier("search-run")
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            if !completions.isEmpty { completionStrip }
            resultsHeader
            CardGridView(items: controller.results, onAppearIndex: { controller.loadMore(near: $0) })
        }
    }

    /// Exact card names starting with what was typed.
    private var completionStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(completions, id: \.self) { name in
                    Button(name) {
                        controller.query.text = name
                        controller.run()
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Card name suggestions")
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
            if controller.isRefreshing || controller.isLoadingMore {
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

    // MARK: Typing

    private func textChanged(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            // Field cleared (the ✕, or Cancel): back to the form. Filters
            // stay set; the Search button runs them on their own.
            controller.clear()
            completions = []
            return
        }
        controller.scheduleRun()
        scheduleCompletions(text)
    }

    /// Name completions from /cards/autocomplete, debounced, skipped for
    /// anything that looks like Scryfall syntax.
    private func scheduleCompletions(_ text: String) {
        completionTask?.cancel()
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, !t.contains(":") else { completions = []; return }
        completionTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let names = (try? await ScryfallClient.shared.autocomplete(t)) ?? []
            guard !Task.isCancelled else { return }
            // Typing the exact name means the strip has nothing to add.
            completions = names.filter { $0.caseInsensitiveCompare(t) != .orderedSame }
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

        if controller.phase != .idle {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    ForEach(SearchSort.allCases) { option in
                        Button {
                            controller.query.sort = option
                            controller.query.direction = nil
                            controller.runIfChanged()
                        } label: {
                            Label(option.label, systemImage: option == controller.query.sort ? "checkmark" : option.systemImage)
                        }
                    }
                    Divider()
                    let current = controller.query.effectiveDirection
                    Button {
                        controller.query.direction = current == .ascending ? .descending : .ascending
                        controller.runIfChanged()
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
    }

    // MARK: Actions

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
