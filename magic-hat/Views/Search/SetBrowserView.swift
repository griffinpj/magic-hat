//
//  SetBrowserView.swift
//  magic-hat
//
//  The Search tab's Sets page: every set Scryfall lists, by release year,
//  each with its symbol, code, size and how many of its cards you own;
//  narrowed by kind (main sets by default) and by the tab's search field.
//  A set pushes its cards (SetCardsView) — a Scryfall search for `s:code`
//  in collector-number order, in the same grid, viewer and Add as any
//  search. The list comes from ScryfallCatalogCache (a day on disk);
//  pulling down fetches it again, which is how a set released this
//  morning appears now.
//

import SwiftUI
import SwiftData

struct SetBrowserView<Header: View>: View {
    /// The tab's search text, filtering set names and codes.
    let filter: String
    /// The tab's Cards | Sets picker, first in the list whatever it shows.
    @ViewBuilder var header: () -> Header

    @Environment(\.modelContext) private var modelContext
    @AppStorage("search.sets.kind") private var kindRaw = SetKind.main.rawValue
    @AppStorage("search.sets.digital") private var includeDigital = false
    @State private var sets: [ScryfallSet] = []
    @State private var sections: [SetSection] = []
    @State private var owned: [String: Int] = [:]
    @State private var failed = false
    @State private var loaded = false
    /// Bumped on every load that returns a list: what the grouping is keyed
    /// on. Keyed on `sets.count`, a refresh that changed a set without
    /// changing how many there are (a release date, a name) never regrouped.
    @State private var loadGeneration = 0

    private var kind: SetKind { SetKind(rawValue: kindRaw) ?? .main }
    private var tracker: CollectionChangeTracker { .shared }

    var body: some View {
        Group {
            if loaded, !(failed && sets.isEmpty), !sections.isEmpty {
                list
            } else {
                VStack(spacing: 0) {
                    header().padding(.horizontal, 16).padding(.top, 8)
                    placeholder
                }
            }
        }
        .task { await load(force: false) }
        .task(id: tracker.revision) { await loadOwned() }
        .task(id: "\(filter)|\(kindRaw)|\(includeDigital)|\(loadGeneration)") { await regroup() }
    }

    @ViewBuilder private var placeholder: some View {
        Group {
            if !loaded {
                ProgressView("Loading sets…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed && sets.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't Load Sets", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("The set list comes from Scryfall.")
                } actions: {
                    Button("Try Again") { Task { await load(force: true) } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search(text: filter)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                header()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            Section {
                kindPicker
            }
            ForEach(sections) { section in
                Section(section.year) {
                    ForEach(section.sets) { set in
                        NavigationLink(value: set) {
                            SetRow(set: set, owned: owned[set.code.lowercased()] ?? 0)
                        }
                        .accessibilityIdentifier("set-row-\(set.code)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await load(force: true) }
    }

    private var kindPicker: some View {
        HStack {
            Menu {
                Picker("Kind", selection: $kindRaw) {
                    ForEach(SetKind.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Include Digital Sets", isOn: $includeDigital)
            } label: {
                HStack(spacing: 6) {
                    Label(kind.label, systemImage: "line.3.horizontal.decrease.circle")
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                }
            }
            .accessibilityIdentifier("sets-kind")
            Spacer()
            Text("\(sections.reduce(0) { $0 + $1.sets.count }) sets")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func load(force: Bool) async {
        do {
            sets = try await ScryfallCatalogCache.shared.sets(forceRefresh: force)
            loadGeneration += 1
            failed = false
        } catch {
            failed = true
        }
        loaded = true
    }

    private func loadOwned() async {
        let store = CollectionStore.shared(for: modelContext.container)
        if let counts = try? await store.ownedCopiesBySet(stamp: .current), !Task.isCancelled { owned = counts }
    }

    /// Grouped off the main actor: a thousand sets, folded per keystroke.
    private func regroup() async {
        let sets = self.sets, kind = self.kind, filter = self.filter, digital = includeDigital
        let grouped = await Task.detached(priority: .userInitiated) {
            SetBrowsing.sections(sets, kind: kind, filter: filter, digital: digital)
        }.value
        guard !Task.isCancelled else { return }
        sections = grouped
    }
}

private struct SetRow: View {
    let set: ScryfallSet
    let owned: Int

    var body: some View {
        HStack(spacing: 12) {
            SetSymbolView(setCode: set.code, size: 26, tint: .primary)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(set.name ?? set.code.uppercased())
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if owned > 0 {
                Label("\(owned)", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("\(owned) owned")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [set.code.uppercased()]
        if let count = set.cardCount { parts.append("\(count) cards") }
        if let date = SetBrowsing.releaseDate(set.releasedAt) { parts.append(date) }
        return parts.joined(separator: " · ")
    }
}

/// One set's cards, in collector-number order: a Scryfall search for the
/// set in the shared grid, paging as it scrolls. The set is the scope;
/// the search field and the Filters sheet (`FilterContext.set`) narrow
/// within it, exactly as the Search tab's do.
struct SetCardsView: View {
    let set: ScryfallSet

    @Environment(\.modelContext) private var modelContext
    @State private var controller = SearchController()
    @State private var owned = 0
    @State private var selection = CardSelection()
    @State private var searchText = ""
    @State private var showFilters = false

    private var tracker: CollectionChangeTracker { .shared }
    /// Filters chosen besides the set itself.
    private var filterCount: Int { controller.query.activeFilterCountBesidesSets }
    private var isNarrowed: Bool { filterCount > 0 || !controller.query.trimmedText.isEmpty }

    var body: some View {
        Group {
            switch controller.phase {
            case .idle, .searching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty where isNarrowed:
                ContentUnavailableView {
                    Label("No Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing in \(set.name ?? set.code.uppercased()) matches the search and filters.")
                } actions: {
                    if filterCount > 0 {
                        Button("Adjust Filters") { showFilters = true }.buttonStyle(.borderedProminent)
                    }
                    Button("Clear") { searchText = ""; controller.query.text = ""; resetFilters(); controller.runIfChanged() }
                }
            case .empty:
                ContentUnavailableView("No Cards", systemImage: "square.stack",
                                       description: Text("Scryfall lists no cards in this set yet."))
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.exclamationmark")
                } description: { Text(message) } actions: {
                    Button("Try Again") { controller.run() }.buttonStyle(.borderedProminent)
                }
            case .results:
                CardGridView(items: controller.resultList, onAppearIndex: { controller.loadMore(near: $0) }, scrollToTop: 0,
                             header: { header }, accessory: {
                                 if !selection.isActive {
                                     SortButton(options: SearchSort.allCases, selected: controller.query.sort, title: \.label,
                                                icon: \.systemImage, direction: controller.query.effectiveDirection,
                                                onDirection: { controller.query.direction = $0; controller.runIfChanged() },
                                                onSelect: { controller.query.sort = $0; controller.query.direction = nil; controller.runIfChanged() },
                                                identifier: "set-sort")
                                 }
                             }, selection: selection)
            }
        }
        .navigationTitle(set.name ?? set.code.uppercased())
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(set.name ?? set.code.uppercased())")
        .searchPresentationToolbarBehavior(.avoidHidingContent)
        .onSubmit(of: .search) { controller.query.text = searchText; controller.runIfChanged() }
        .onChange(of: searchText) { _, text in controller.scheduleText(text) }
        .toolbar {
            if !selection.isActive {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showFilters = true
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease")
                            .symbolVariant(filterCount > 0 ? .circle.fill : .circle)
                            .foregroundStyle(filterCount > 0 ? Color.accentColor : Color.primary)
                    }
                    .accessibilityIdentifier("set-filters")
                    .accessibilityValue(filterCount > 0 ? "\(filterCount) active" : "none")
                    Menu {
                        Button("Select Cards", systemImage: "checkmark.circle") { selection.begin() }
                            .disabled(controller.results.isEmpty)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("set-more")
                }
            }
        }
        .sheet(isPresented: $showFilters, onDismiss: { pinSet(); controller.runIfChanged() }) {
            SearchFiltersView(query: $controller.query, context: .set)
        }
        .cardSelectionBar(selection, items: controller.resultList)
        .task {
            guard controller.phase == .idle else { return }
            var q = CardSearchQuery()
            q.sets = [set.code.lowercased()]
            q.groupPrintings = false
            q.excludeExtras = false
            q.sort = .set
            q.direction = .ascending
            controller.query = q
            controller.run()
        }
        .task(id: "\(tracker.revision)|\(DeckChangeTracker.shared.revision)") {
            let store = CollectionStore.shared(for: modelContext.container)
            if let index = try? await store.ownedIndex(stamp: .current) { controller.updateOwned(index) }
            if let counts = try? await store.ownedCopiesBySet(stamp: .current) { owned = counts[set.code.lowercased()] ?? 0 }
        }
    }

    /// The set stays the scope whatever the sheet did.
    private func pinSet() {
        controller.query.sets = [set.code.lowercased()]
    }

    private func resetFilters() {
        controller.query.clearFilters()
        pinSet()
    }

    private var header: some View {
        HStack(spacing: 12) {
            SetSymbolView(setCode: set.code, size: 36, tint: .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text([set.code.uppercased(), SetBrowsing.releaseDate(set.releasedAt)].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.medium))
                Text([set.cardCount.map { "\($0) cards" }, owned > 0 ? "\(owned) owned" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}
