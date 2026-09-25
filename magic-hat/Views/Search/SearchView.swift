//
//  SearchView.swift
//  magic-hat
//
//  The Search tab. Two states of one screen:
//
//  - Nothing searched yet: the filters *are* the page — a Form with saved
//    searches at the top and every filter inline, and a prominent Search
//    button in the navigation bar. Typing in the search field runs live
//    (debounced), so the first results appear as you type.
//  - Results: the shared CardGridView. Filters move behind the toolbar
//    icon (the same sections, in a sheet over a draft) so a search can be
//    refined without leaving it; an X clears the search and returns to the
//    form. Emptying the field keeps the results if filters are active (they
//    are still a search) and returns to the form only when nothing else is.
//
//  Name completions are the distinct names *in the results*, so they obey
//  the active filters — Scryfall's autocomplete endpoint takes only a
//  prefix and would offer cards the filters exclude. They scroll with the
//  grid as its header rather than sitting in a bar above it.
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
    /// The field's text, separate from `controller.query.text`: the landing
    /// Form observes the query, so binding the field to it re-diffed every
    /// section on each keystroke. The text reaches the query on the
    /// debounce, on Return, or when a chip is tapped.
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var showSavedList = false
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @FocusState private var focusedField: FilterField?
    /// Bumped to collapse the search field (see SearchDismisser).
    @State private var dismissSearchTrigger = 0

    private var tracker: CollectionChangeTracker { .shared }

    var body: some View {
        NavigationStack {
            content
                .background { SearchDismisser(trigger: dismissSearchTrigger, isEmpty: searchText.isEmpty) }
                .navigationTitle("Search")
                // Always shown; with .automatic the drawer starts hidden above a
                // long Form until the user pulls down.
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "Card name, type, rules text")
                // Live results are refined *while* the field is active, so
                // the title and the Sort/Filters items must stay; by default
                // an active search hides them and only Cancel remains.
                .searchPresentationToolbarBehavior(.avoidHidingContent)
                .onSubmit(of: .search) { submit() }
                .onChange(of: searchText) { _, text in textChanged(text) }
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
        ScrollViewReader { proxy in
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
            SearchFilterSections(query: $controller.query, focused: $focusedField, scrollProxy: proxy)
            Section {
                Button("Reset Filters", role: .destructive) { controller.query.clearFilters() }
                    .frame(maxWidth: .infinity)
                    .disabled(!controller.query.hasFilters)
                    .accessibilityIdentifier("filters-reset")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        }
    }

    private var results: some View {
        CardGridView(items: controller.resultList, onAppearIndex: { controller.loadMore(near: $0) }, header: {
            let names = completions
            if !names.isEmpty { completionStrip(names) }
        })
        // Quiet progress: a small pill while a new first page replaces
        // what's shown, or the next page is on its way.
        .overlay(alignment: .top) {
            if controller.isRefreshing { progressPill.padding(.top, 8) }
        }
        .overlay(alignment: .bottom) {
            if controller.isLoadingMore { progressPill.padding(.bottom, 12) }
        }
    }

    private var progressPill: some View {
        ProgressView()
            .controlSize(.small)
            .padding(10)
            .glassEffect(.regular, in: Circle())
    }

    /// Distinct card names in the current results that match the typed
    /// text, prefix matches first — filter-aware by construction.
    private var completions: [String] {
        let t = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !t.contains(":") else { return [] }
        var seen = Set<String>()
        var prefix: [String] = [], contains: [String] = []
        for item in controller.results.prefix(200) {
            let name = item.name
            guard !seen.contains(name), name.caseInsensitiveCompare(t) != .orderedSame else { continue }
            seen.insert(name)
            if name.range(of: t, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil {
                prefix.append(name)
            } else if name.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                contains.append(name)
            }
        }
        return Array((prefix + contains).prefix(8))
    }

    private func completionStrip(_ names: [String]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button(name) {
                        searchText = name
                        submit()
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .lineLimit(1)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .accessibilityLabel("Card name suggestions")
    }

    // MARK: Typing

    private func submit() {
        controller.query.text = searchText
        controller.run()
    }

    private func textChanged(_ text: String) {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            if controller.phase == .idle {
                controller.query.text = ""      // already on the form
            } else if controller.query.hasFilters {
                controller.scheduleText("")     // filters are still a search
            } else {
                controller.clear()              // nothing left: back to the form
                controller.query.text = ""
            }
            return
        }
        controller.scheduleText(text)
    }

    /// The toolbar X: drop the search and return to the form. Filters stay
    /// set — the form shows them, and Reset is right there.
    private func clearSearch() {
        controller.clear()
        controller.query.text = ""
        searchText = ""
        dismissSearchTrigger += 1
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

        if controller.phase == .idle {
            // The filters are on screen; the one action left is to run them.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search") {
                    focusedField = nil
                    controller.run()
                }
                .buttonStyle(.glassProminent)
                .disabled(controller.query.isEmpty)
                .accessibilityIdentifier("search-run")
            }
        } else {
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
                        .foregroundStyle(controller.query.hasFilters ? Color.accentColor : Color.primary)
                }
                .accessibilityIdentifier("search-filters")
                .accessibilityValue(controller.query.hasFilters ? "\(controller.query.activeFilterCount) active" : "none")

                Button("Clear Search", systemImage: "xmark") { clearSearch() }
                    .accessibilityIdentifier("search-clear")
            }
        }
    }

    // MARK: Actions

    private func load(_ saved: SavedSearch) {
        saved.lastUsedDate = Date()
        controller.query = saved.query
        searchText = saved.query.text
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
        guard let ids = try? await store.ownedScryfallIDs(stamp: .current), !Task.isCancelled else { return }
        controller.updateOwned(ids)
    }
}

#Preview {
    SearchView()
        .modelContainer(for: [SavedSearch.self, CollectionEntry.self, CardMeta.self], inMemory: true)
}
