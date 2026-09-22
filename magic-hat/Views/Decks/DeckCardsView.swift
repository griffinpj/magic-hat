//
//  DeckCardsView.swift
//  magic-hat
//
//  The Cards tab of a deck. Two modes behind one search field:
//
//  - Unlocked: the field *adds* cards. Results come from the collection
//    (in memory, one row per card with the copies owned) or from Scryfall
//    (All Cards), narrowed by the same filter sheet as everywhere else and,
//    for commander decks, by the commander's colour identity. A board
//    picker says where "+" puts the card; tapping a row opens the viewer,
//    whose Add goes to the same board.
//  - Locked: the field *filters* the deck; nothing can be added or counted.
//
//  With no search, the list itself: commander, then the mainboard grouped
//  by type with counts and value, then sideboard and maybeboard. Each row
//  shows what the collection can do about it — built, available, missing.
//

import SwiftUI
import SwiftData

struct DeckCardsView: View {
    let snapshot: DeckSnapshot

    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var query = CardSearchQuery()
    @State private var scope: DeckSearchScope = .collection
    @State private var board: DeckBoard = .main
    @State private var identityFilter = true
    @State private var showFilters = false
    @State private var controller = SearchController()
    @State private var owned: [CardItem] = []
    @State private var ownedLoaded = false
    @State private var collectionResults: [DeckSearchResult] = []
    @State private var collectionTask: Task<Void, Never>?
    @State private var viewerItems: [CardItem] = []
    @State private var viewing: CardItem?
    @State private var viewingID: String?
    @State private var addCount = 0
    @State private var error: String?
    @State private var dismissTrigger = 0

    private var collectionTracker: CollectionChangeTracker { .shared }

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || query.hasFilters }
    private var locked: Bool { snapshot.isLocked }
    private var usesIdentity: Bool { snapshot.format.hasCommander && !snapshot.commanders.isEmpty }

    /// Copies already on each board, by card, for the "in deck" badges.
    private var inDeckByKey: [DeckBoard: [String: Int]] {
        var out: [DeckBoard: [String: Int]] = [:]
        for item in snapshot.allItems {
            out[item.board, default: [:]][item.card.oracleID ?? item.card.scryfallID, default: 0] += item.quantity
        }
        return out
    }

    var body: some View {
        content
            .background { SearchDismisser(trigger: dismissTrigger, isEmpty: searchText.isEmpty) }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: locked ? "Search this deck" : "Add cards")
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .onSubmit(of: .search) { runSearch(immediately: true) }
            .onChange(of: searchText) { _, _ in runSearch(immediately: false) }
            .onChange(of: query) { _, _ in runSearch(immediately: true) }
            .onChange(of: scope) { _, _ in runSearch(immediately: true) }
            .onChange(of: identityFilter) { _, _ in runSearch(immediately: true) }
            .sheet(isPresented: $showFilters) {
                SearchFiltersView(query: $query, context: scope == .collection ? .collection : .scryfall)
            }
            .fullScreenCover(item: $viewing, onDismiss: { viewingID = nil }) { item in
                CardViewerView(items: viewerItems, currentID: $viewingID,
                               deckTarget: locked ? nil : DeckAddTarget(deckID: snapshot.id, deckName: snapshot.name, board: board))
            }
            .sensoryFeedback(.success, trigger: addCount)
            .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .task(id: collectionTracker.revision) { await loadOwned() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if isSearching, !locked {
            VStack(spacing: 0) {
                searchHeader
                searchResults
            }
        } else {
            deckList
        }
    }

    /// Scope, board and identity live above the results, not in the
    /// filter sheet: they change what "+" means, and they change often.
    private var searchHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Source", selection: $scope) {
                    ForEach(DeckSearchScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("deck-search-scope")
                Menu {
                    ForEach(DeckBoard.addable) { b in
                        Button { board = b } label: {
                            Label(b.label, systemImage: b == board ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(board.label)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                }
                .menuOrder(.fixed)
                .accessibilityIdentifier("deck-search-board")
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .symbolVariant(query.hasFilters ? .circle.fill : .circle)
                        .foregroundStyle(query.hasFilters ? Color.accentColor : Color.primary)
                }
                .accessibilityLabel("Filters")
                .accessibilityIdentifier("deck-search-filters")
            }
            if usesIdentity {
                Toggle(isOn: $identityFilter) {
                    HStack(spacing: 4) {
                        Text("Within identity")
                        ForEach(snapshot.identity, id: \.self) { color in
                            ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 14)
                        }
                    }
                    .font(.footnote)
                }
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var searchResults: some View {
        switch scope {
        case .collection:
            if !ownedLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if collectionResults.isEmpty {
                ContentUnavailableView("Nothing in Your Collection", systemImage: "tray",
                                       description: Text("Try All Cards to search everything."))
            } else {
                List(collectionResults) { result in
                    resultRow(result.card, ownedCopies: result.ownedCopies)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
        case .all:
            switch controller.phase {
            case .idle:
                ContentUnavailableView("Search All Cards", systemImage: "magnifyingglass",
                                       description: Text("Type a name, or set filters."))
            case .searching:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                ContentUnavailableView.search(text: searchText)
            case .failed(let message):
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(message))
            case .results:
                List(Array(controller.results.enumerated()), id: \.element.id) { index, item in
                    resultRow(item, ownedCopies: ownedCopies(for: item))
                        .onAppear { controller.loadMore(near: index) }
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    private func resultRow(_ item: CardItem, ownedCopies: Int?) -> some View {
        let key = item.oracleID ?? item.scryfallID
        let legalKey = snapshot.format.legalityKey
        let notLegal = legalKey.flatMap { item.legalities?[$0] }.map { $0 != "legal" } ?? false
        return DeckSearchRow(
            item: item, ownedCopies: ownedCopies, inDeck: inDeckByKey[board]?[key] ?? 0,
            notLegal: notLegal, onAdd: { add(item) }
        )
        .onTapGesture { open(item) }
    }

    // MARK: Deck list

    @ViewBuilder private var deckList: some View {
        let filtered = locked && isSearching ? filteredSnapshotItems : nil
        if snapshot.allItems.isEmpty {
            ContentUnavailableView {
                Label("Empty Deck", systemImage: "rectangle.stack")
            } description: {
                Text(locked ? "Unlock the deck to add cards." : "Search above to add cards from your collection or all of Magic.")
            }
        } else if let filtered, filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if let filtered {
                    Section("\(filtered.count) matching") {
                        ForEach(filtered) { row($0) }
                    }
                } else {
                    if snapshot.format.hasCommander || !snapshot.commanders.isEmpty {
                        Section {
                            ForEach(snapshot.commanders) { row($0) }
                            if snapshot.commanders.isEmpty {
                                Text("No commander chosen").foregroundStyle(.secondary)
                            }
                        } header: {
                            Label("Commander", systemImage: "crown")
                        }
                    }
                    ForEach(snapshot.sections) { section in
                        Section {
                            ForEach(section.items) { row($0) }
                        } header: {
                            HStack {
                                if let glyph = section.glyph {
                                    ManaGlyphView(name: glyph, size: 14)
                                }
                                Text(section.title)
                                Spacer()
                                Text("\(section.copies) · \(PriceFormat.compact(section.value))")
                                    .monospacedDigit()
                            }
                        }
                    }
                    if !snapshot.sideboard.isEmpty {
                        Section("Sideboard · \(snapshot.sideboard.reduce(0) { $0 + $1.quantity })") {
                            ForEach(snapshot.sideboard) { row($0) }
                        }
                    }
                    if !snapshot.maybeboard.isEmpty {
                        Section("Maybeboard · \(snapshot.maybeboard.reduce(0) { $0 + $1.quantity })") {
                            ForEach(snapshot.maybeboard) { row($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func row(_ item: DeckCardItem) -> some View {
        DeckCardRow(item: item, locked: locked) { setQuantity(item, $0) }
            .onTapGesture { openDeckItem(item) }
            .contextMenu {
                if !locked {
                    ForEach(DeckBoard.addable.filter { $0 != item.board }) { b in
                        Button("Move to \(b.label)", systemImage: "arrow.right") { move(item, to: b) }
                    }
                    if snapshot.format.hasCommander, item.board != .commander {
                        Button("Set as Commander", systemImage: "crown") { setCommander(item) }
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { setQuantity(item, 0) }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !locked {
                    Button("Remove", systemImage: "trash", role: .destructive) { setQuantity(item, 0) }
                }
            }
    }

    /// Locked: the field and filters narrow the deck itself.
    private var filteredSnapshotItems: [DeckCardItem] {
        var q = query
        q.text = searchText
        return snapshot.allItems.filter { q.matches($0.card) }
    }

    // MARK: Search

    /// The query actually run: the user's filters plus the commander's
    /// colour identity. Format legality is *shown* on each result ("Not
    /// legal"), not enforced: a card whose legality isn't cached yet would
    /// otherwise vanish, and the user may want it anyway.
    private func effectiveQuery() -> CardSearchQuery {
        var q = query
        q.text = searchText
        if usesIdentity, identityFilter {
            q.useColorIdentity = true
            if snapshot.identity.isEmpty {
                q.colors = []
                q.colorless = true
            } else {
                q.colors = Set(snapshot.identity)
                q.colorMode = .atMost
            }
        }
        return q
    }

    private func runSearch(immediately: Bool) {
        guard !locked else { return }
        guard isSearching else {
            controller.clear()
            collectionResults = []
            return
        }
        switch scope {
        case .all:
            let q = effectiveQuery()
            controller.query = q
            if immediately { controller.run() } else { controller.scheduleRun() }
        case .collection:
            collectionTask?.cancel()
            let q = effectiveQuery()
            let all = owned
            collectionTask = Task.detached(priority: .userInitiated) {
                if !immediately { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let results = Self.groupOwned(all.filter { q.matches($0) })
                guard !Task.isCancelled else { return }
                await MainActor.run { collectionResults = results }
            }
        }
    }

    /// One row per card across every printing owned, copies summed.
    nonisolated private static func groupOwned(_ items: [CardItem]) -> [DeckSearchResult] {
        var byKey: [String: DeckSearchResult] = [:]
        for item in items {
            let key = item.oracleID ?? item.scryfallID
            if var existing = byKey[key] {
                existing = DeckSearchResult(card: existing.card, ownedCopies: existing.ownedCopies + item.quantity)
                byKey[key] = existing
            } else {
                byKey[key] = DeckSearchResult(card: item, ownedCopies: item.quantity)
            }
        }
        return byKey.values.sorted { $0.card.sortKey < $1.card.sortKey }
    }

    private func ownedCopies(for item: CardItem) -> Int {
        let key = item.oracleID ?? item.scryfallID
        return owned.filter { ($0.oracleID ?? $0.scryfallID) == key }.reduce(0) { $0 + $1.quantity }
    }

    private func loadOwned() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let cards = try? await store.ownedCards(), !Task.isCancelled {
            owned = cards
        }
        ownedLoaded = true
        if isSearching, scope == .collection { runSearch(immediately: true) }
    }

    // MARK: Actions

    private func add(_ item: CardItem) {
        do {
            try DeckEditController.add(PrintingSelection(item: item), to: snapshot.id, board: board, context: modelContext)
            addCount += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setQuantity(_ item: DeckCardItem, _ quantity: Int) {
        do { try DeckEditController.setQuantity(deckCardID: item.id, quantity, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func move(_ item: DeckCardItem, to board: DeckBoard) {
        do { try DeckEditController.move(deckCardID: item.id, to: board, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func setCommander(_ item: DeckCardItem) {
        do {
            try DeckEditController.setCommander(deckID: snapshot.id, PrintingSelection(item: item.card), context: modelContext)
            try DeckEditController.setQuantity(deckCardID: item.id, 0, context: modelContext)
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ item: CardItem) {
        viewerItems = scope == .collection ? collectionResults.map(\.card) : controller.results
        viewingID = item.id
        viewing = item
    }

    private func openDeckItem(_ item: DeckCardItem) {
        viewerItems = snapshot.allItems.map(\.card)
        viewingID = item.card.id
        viewing = item.card
    }
}

/// A card found in the collection by a deck's search.
nonisolated struct DeckSearchResult: Identifiable, Hashable, Sendable {
    let card: CardItem
    let ownedCopies: Int
    var id: String { card.oracleID ?? card.scryfallID }
}
