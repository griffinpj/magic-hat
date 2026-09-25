//
//  DeckAddCardsView.swift
//  magic-hat
//
//  Adding cards to a deck, as its own sheet — the shape of "Add to
//  Playlist" in Music: a search field focused on arrival, results from the
//  collection or from all of Magic, "+" on every row, Done when finished.
//  A sheet rather than a mode of the deck screen's own field: the mode had
//  nowhere natural for Filters, the section picker had to step aside, and
//  Back left the deck instead of the search.
//
//  Scope and board sit in a header under the field, not in the filter
//  sheet: they change what "+" means, and they change often. Two scopes:
//  All Cards and Recommended. "In collection" is a chip on either, like
//  "Within identity": on All Cards it turns the Scryfall search into a
//  search of what is owned (and, with nothing typed, a browse of it, so a
//  deck can be built from the shelf); on Recommended it narrows the
//  suggestions to what is owned. Recommended leads with the commander's
//  synergy list from EDHREC — every card played with it beyond chance,
//  best first, the ones already in the deck left out — then the
//  analysis's own list for this deck (DeckAnalysisController): the
//  collection's spare cards, the meta's picks and the missing pieces of
//  one-card-away combos, ranked, each row saying why. Adding is what a
//  recommendation is for, so it lives where adding happens. The lists
//  are read off-main and take a moment on a big collection; the scope
//  shows a loader until they land and keeps a card just added in its
//  place as a stepper (the next plan leaves it out, since it is in the
//  deck now). A row already on the board is a stepper, and so is
//  the viewer's toolbar; both read DeckAddSession, refreshed from the
//  snapshot after every deck write. Commander decks add the commander's colour identity
//  as `id<=` (a toggle shows it). Format legality is tagged on each result
//  ("Not legal"), not enforced: enforcing it hid every card whose legality
//  wasn't cached yet. Colour identity is tagged the same way ("Outside
//  identity") once the toggle is off.
//
//  An add that breaks a rule of the format — the 101st card, a card outside
//  the commander's identity, a second copy in a singleton deck — goes
//  through: cutting down is how decks get built, and an alert on every "+"
//  would be the wrong tool (HIG: alerts for what needs a decision). It is
//  answered with the warning haptic instead of the success one, and the
//  header carries a line naming what the deck now breaks, live from the
//  snapshot, so the state is visible the whole time the sheet is open.
//

import SwiftUI
import SwiftData

struct DeckAddCardsView: View {
    let deckID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Namespace private var zoom

    /// Board and per-card counts, shared with the viewer.
    @State private var session: DeckAddSession
    @State private var snapshot: DeckSnapshot?
    @State private var searchText = ""
    @State private var query = CardSearchQuery()
    @State private var scope: DeckSearchScope
    @State private var identityFilter = true
    /// The "In collection" chip: only what is owned.
    @State private var ownedOnly: Bool
    @State private var showFilters = false
    @State private var controller = SearchController()
    /// Every owned row (stamped: a `@State` array of cards is compared card
    /// by card by the parent, see CardItemList) and copies per card key.
    @State private var owned = CardItemList()
    @State private var ownedByKey: [String: Int] = [:]
    @State private var ownedLoaded = false
    /// Cards left out of the untyped listing (see `browseLimit`).
    @State private var collectionHidden = 0
    /// The collection scope's rows: the cards (stamped) and copies owned
    /// by card id. Two values rather than one array of results because
    /// SwiftUI compares a List's data element by element (see CardItemList).
    @State private var collectionCards = CardItemList()
    @State private var collectionOwned: [String: Int] = [:]
    @State private var collectionTask: Task<Void, Never>?
    /// The Recommended scope: the plan's list as shown (a card just put
    /// in kept in place), then the rows matching the field and filters.
    @State private var recommendedShown: [DeckRecommendation] = []
    @State private var recommended = CardItemList()
    @State private var recommendedReasons: [String: CardReason] = [:]
    @State private var recommendedOwned: [String: Int] = [:]
    /// The commander's synergy list as shown: EDHREC's picks not yet in
    /// the deck, narrowed by the field, the filters and the chip.
    @State private var synergyShown = CardItemList()
    @State private var synergyReasons: [String: CardReason] = [:]
    @State private var synergyOwned: [String: Int] = [:]
    @State private var viewer: CardViewerSession?
    @State private var addCount = 0
    /// Whether the last add broke a rule; picks the haptic.
    @State private var lastAddBroke = false
    @State private var error: String?
    @FocusState private var searchFocused: Bool

    /// With nothing typed and "In collection" on, All Cards lists what's
    /// owned; a List of every card in a real collection (3,800 rows) costs
    /// SwiftUI a third of a second to build its identity list on every
    /// update, so browsing shows this many and a footer says the rest are
    /// a search away.
    private static let browseLimit = 400

    /// "+" opens on All Cards with the chip on (build from the shelf);
    /// Recommended opens with it off, since the point there is what the
    /// collection lacks.
    init(deckID: UUID, context: ModelContext, scope: DeckSearchScope = .all) {
        self.deckID = deckID
        _session = State(initialValue: DeckAddSession(deckID: deckID, context: context))
        _scope = State(initialValue: scope)
        _ownedOnly = State(initialValue: scope == .all)
    }

    private var deckTracker: DeckChangeTracker { .shared }
    private var collectionTracker: CollectionChangeTracker { .shared }
    /// One per deck for the app's life; the deck screen shares it.
    private var analysis: DeckAnalysisController { .shared(for: deckID) }

    private var hasCriteria: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty || query.hasFilters }
    private var identity: [ManaColor] { snapshot?.identity ?? [] }
    private var usesIdentity: Bool {
        guard let snapshot else { return false }
        return snapshot.format.hasCommander && !snapshot.commanders.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    header
                    results
                }
                // While the viewer pages, keep the row it is on in view, so
                // the zoom-out lands on that row's art.
                .onChange(of: viewer?.currentID) { old, id in
                    guard old != nil, let id else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(id) }
                }
            }
            .navigationTitle("Add Cards")
            .navigationSubtitle(snapshot?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Card name, type, rules text")
            .searchFocused($searchFocused)
            // Filters and Done stay while typing; there is no Back here to
            // collide with.
            .searchPresentationToolbarBehavior(.avoidHidingContent)
            .onSubmit(of: .search) { runSearch(immediately: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filtersButton }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("deck-add-done")
                }
            }
            .sheet(isPresented: $showFilters) {
                // Everything but a Scryfall search is matched in memory.
                SearchFiltersView(query: $query, context: scope == .all && !ownedOnly ? .scryfall : .collection)
            }
            .fullScreenCover(item: $viewer) { v in
                CardViewerView(items: v.items, currentID: Bindable(v).currentID, deck: v.deck)
                    .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
            }
            .sensoryFeedback(trigger: addCount) { _, _ in lastAddBroke ? .warning : .success }
            .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
            .onChange(of: searchText) { _, _ in runSearch(immediately: false) }
            .onChange(of: query) { _, _ in runSearch(immediately: true) }
            .onChange(of: scope) { _, _ in runSearch(immediately: true) }
            .onChange(of: identityFilter) { _, _ in runSearch(immediately: true) }
            .onChange(of: ownedOnly) { _, _ in runSearch(immediately: true) }
            .onChange(of: session.board) { _, _ in runSearch(immediately: true) }
            .onChange(of: analysis.plan?.id) { _, _ in mergeRecommendations() }
            .onChange(of: analysis.synergyVersion) { _, _ in if scope == .recommended { runSearch(immediately: true) } }
            .task(id: deckTracker.revision) { await loadDeck() }
            .task(id: collectionTracker.revision) { await loadOwned() }
            .onAppear { searchFocused = true }
        }
    }

    // MARK: Header

    private var filtersButton: some View {
        Button {
            showFilters = true
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease")
                .symbolVariant(query.hasFilters ? .circle.fill : .circle)
                .foregroundStyle(query.hasFilters ? Color.accentColor : Color.primary)
        }
        .accessibilityIdentifier("deck-search-filters")
        .accessibilityValue(query.hasFilters ? "\(query.activeFilterCount) active" : "none")
    }

    /// The two scopes across the top; the chips on the row beneath; the
    /// board "+" adds to, with the deck's issues, on the row under that.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $scope) {
                ForEach(DeckSearchScope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("deck-search-scope")
            HStack(spacing: 8) {
                Toggle(isOn: $ownedOnly) {
                    Label("In collection", systemImage: "tray.full")
                        .font(.footnote)
                }
                .toggleStyle(.button)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityIdentifier("deck-search-owned")
                if usesIdentity {
                    Toggle(isOn: $identityFilter) {
                        HStack(spacing: 4) {
                            Text("Within identity")
                            ForEach(identity, id: \.self) { color in
                                ManaSymbolView(symbol: ManaSymbol(color.rawValue), size: 14)
                            }
                        }
                        .font(.footnote)
                    }
                    .toggleStyle(.button)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                if let snapshot, !snapshot.stats.violations.isEmpty {
                    Label {
                        Text(snapshot.stats.violationSummary)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                    .lineLimit(2)
                    .accessibilityIdentifier("deck-add-issues")
                }
                Spacer(minLength: 0)
                boardMenu
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Where "+" puts a card. A row's context menu offers the others.
    private var boardMenu: some View {
        Menu {
            ForEach(DeckBoard.addable, id: \.rawValue) { b in
                Button {
                    session.board = b
                } label: {
                    if b == session.board {
                        Label(b.label, systemImage: "checkmark")
                    } else {
                        Text(b.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.board.label)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
        }
        .menuOrder(.fixed)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Add to \(session.board.label)")
        .accessibilityIdentifier("deck-search-board")
    }

    // MARK: Results

    @ViewBuilder private var results: some View {
        switch scope {
        case .all:
            if ownedOnly { collectionResults } else { scryfallResults }
        case .recommended:
            recommendedResults
        }
    }

    /// All Cards with the chip on: what is owned, matched in memory.
    @ViewBuilder private var collectionResults: some View {
        if !ownedLoaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if collectionCards.isEmpty {
            if owned.isEmpty {
                ContentUnavailableView {
                    Label("No Cards in Your Collection", systemImage: "tray")
                } description: {
                    Text("Import or add cards first, or search every card.")
                } actions: {
                    Button("Search All Cards") { ownedOnly = false }
                }
            } else {
                ContentUnavailableView {
                    Label("Nothing in Your Collection", systemImage: "tray")
                } description: {
                    Text("No owned card matches. Turn off In collection to search everything.")
                } actions: {
                    Button("Search All Cards") { ownedOnly = false }
                }
            }
        } else {
            List {
                ForEach(collectionCards.ids, id: \.self) { id in
                    if let card = collectionCards.item(for: id) {
                        resultRow(card, ownedCopies: collectionOwned[id])
                            .id(id)
                    }
                }
                if collectionHidden > 0 {
                    Text("\(collectionHidden) more cards — type to search them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// All Cards with the chip off: Scryfall.
    @ViewBuilder private var scryfallResults: some View {
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
            let results = controller.resultList
            List {
                ForEach(results.ids, id: \.self) { id in
                    if let item = results.item(for: id) {
                        resultRow(item, ownedCopies: ownedCopies(for: item))
                            .id(id)
                            .onAppear { controller.loadMore(near: results.index(of: id) ?? 0) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// The commander's synergies first, then the analysis's list.
    @ViewBuilder private var recommendedResults: some View {
        if analysis.analysis == nil || (analysis.plan == nil && analysis.isPlanning) {
            // The plan reads every spare card in the collection, off the
            // main actor; on a big one that is a second or two.
            ProgressView("Reading the collection…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("deck-recommended-loading")
        } else {
            List {
                if usesIdentity { synergySection }
                Section {
                    if recommended.isEmpty {
                        Text(analysis.plan == nil ? "Add a few cards and a commander first."
                             : (hasCriteria || ownedOnly ? "Nothing here matches." : "Every card that would help is already in the list."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(recommended.ids, id: \.self) { id in
                        if let card = recommended.item(for: id) {
                            resultRow(card, ownedCopies: recommendedOwned[id], reason: recommendedReasons[id])
                                .id(id)
                        }
                    }
                } header: {
                    Text("For This Deck")
                } footer: {
                    Text(analysis.sourcesLine)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var synergySection: some View {
        Section {
            switch analysis.synergies {
            case .pending:
                HStack(spacing: 12) { ProgressView(); Text("Asking EDHREC…").foregroundStyle(.secondary) }
            case .offline:
                Text("Needs a connection.").foregroundStyle(.secondary)
            case .unavailable:
                Text("EDHREC has nothing for this commander.").foregroundStyle(.secondary)
            case .done:
                if synergyShown.isEmpty {
                    Text(hasCriteria || ownedOnly ? "Nothing here matches." : "Every synergy card is already in the deck.")
                        .foregroundStyle(.secondary)
                }
                ForEach(synergyShown.ids, id: \.self) { id in
                    if let card = synergyShown.item(for: id) {
                        resultRow(card, ownedCopies: synergyOwned[id], reason: synergyReasons[id])
                            .id(id)
                    }
                }
            }
        } header: {
            // On the header, not the Section: a Section's identifier is
            // stamped on every child, hiding the rows' own.
            Text("Commander Synergies")
                .accessibilityIdentifier("deck-recommended-synergies")
        } footer: {
            Text("EDHREC, best first")
        }
    }

    private func resultRow(_ item: CardItem, ownedCopies: Int?, reason: CardReason? = nil) -> some View {
        let legalKey = snapshot?.format.legalityKey
        let notLegal = legalKey.flatMap { item.legalities?[$0] }.map { $0 != "legal" } ?? false
        return DeckSearchRow(
            item: item, ownedCopies: ownedCopies, inDeck: session.quantity(of: item), notLegal: notLegal,
            offIdentity: isOffIdentity(item), reason: reason,
            zoom: zoom, onSetQuantity: { setQuantity(item, $0) }, onOpen: { open(item) }
        )
        // `id: \.rawValue`, not the Identifiable default: the generic `\.id`
        // key path is re-instantiated per row, resolving generic arguments
        // by mangled name — 0.25s over the first rows of a debug build.
        .contextMenu {
            ForEach(DeckBoard.addable, id: \.rawValue) { b in
                Button("Add to \(b.label)", systemImage: "plus") { add(item, to: b) }
            }
        }
    }

    // MARK: Search

    /// The user's text and filters, plus the commander's colour identity.
    private func effectiveQuery() -> CardSearchQuery {
        var q = query
        q.text = searchText
        if usesIdentity, identityFilter {
            q.useColorIdentity = true
            if identity.isEmpty {
                q.colors = []
                q.colorless = true
            } else {
                q.colors = Set(identity)
                q.colorMode = .atMost
            }
        }
        return q
    }

    private func runSearch(immediately: Bool) {
        switch scope {
        case .recommended:
            // A few hundred rows at most: the match runs where it is asked.
            let q = effectiveQuery()
            // What the deck already plays is not offered; what this sheet
            // put in stays, as a stepper (see `DeckAddSession.touched`).
            let inDeck = Set((snapshot?.playedItems ?? []).map { DeckAddSession.key(of: $0.card) })
            let keeps = { (card: CardItem) -> Bool in session.touched.contains(DeckAddSession.key(of: card)) }
            let picks = analysis.commanderPicks.filter { pick in
                let key = DeckAddSession.key(of: pick.card)
                if inDeck.contains(key) && !keeps(pick.card) { return false }
                if ownedOnly && pick.ownedCopies == 0 && !keeps(pick.card) { return false }
                return q.isEmpty || q.matches(pick.card)
            }
            synergyShown = CardItemList(picks.map(\.card))
            synergyReasons = Dictionary(picks.map { ($0.card.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
            synergyOwned = Dictionary(picks.map { ($0.card.id, $0.ownedCopies) }, uniquingKeysWith: { a, _ in a })
            // The synergy list leads; a card on it is not listed twice.
            let led = Set(picks.map { DeckAddSession.key(of: $0.card) })
            let rows = recommendedShown.filter { rec in
                if led.contains(DeckAddSession.key(of: rec.card)) { return false }
                if ownedOnly && !rec.isOwned && !keeps(rec.card) { return false }
                return q.isEmpty || q.matches(rec.card)
            }
            recommended = CardItemList(rows.map(\.card))
            recommendedReasons = Dictionary(rows.map { ($0.card.id, $0.reason) }, uniquingKeysWith: { a, _ in a })
            recommendedOwned = Dictionary(rows.map { ($0.card.id, $0.candidate.ownedCopies) }, uniquingKeysWith: { a, _ in a })
        case .all where !ownedOnly:
            guard hasCriteria else { controller.clear(); return }
            controller.query = effectiveQuery()
            if immediately { controller.run() } else { controller.scheduleRun() }
        case .all:
            collectionTask?.cancel()
            let q = effectiveQuery()
            let all = owned.items
            let typed = q.trimmedText
            let limit = Self.browseLimit
            collectionTask = Task.detached(priority: .userInitiated) {
                if !immediately { try? await Task.sleep(for: .milliseconds(150)) }
                guard !Task.isCancelled else { return }
                let results = Self.groupOwned(q.isEmpty ? all : all.filter { q.matches($0) }, typed: typed)
                let shown = q.isEmpty ? Array(results.prefix(limit)) : results
                let cards = CardItemList(shown.map(\.card))
                let owned = Dictionary(shown.map { ($0.card.id, $0.ownedCopies) }, uniquingKeysWith: { a, _ in a })
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    collectionCards = cards
                    collectionOwned = owned
                    collectionHidden = results.count - shown.count
                }
            }
        }
    }

    /// One row per card across every printing owned, copies summed. Names
    /// that start with what was typed come first ("Card 7" before "Card
    /// 107"), then everything alphabetically.
    nonisolated private static func groupOwned(_ items: [CardItem], typed: String) -> [DeckSearchResult] {
        var byKey: [String: DeckSearchResult] = [:]
        for item in items {
            let key = item.oracleID ?? item.scryfallID
            if let existing = byKey[key] {
                byKey[key] = DeckSearchResult(card: existing.card, ownedCopies: existing.ownedCopies + item.quantity)
            } else {
                byKey[key] = DeckSearchResult(card: item, ownedCopies: item.quantity)
            }
        }
        let prefix = CardItem.sortKey(for: typed)
        return byKey.values.sorted { a, b in
            if !prefix.isEmpty {
                let ap = a.card.sortKey.hasPrefix(prefix), bp = b.card.sortKey.hasPrefix(prefix)
                if ap != bp { return ap }
            }
            return a.card.sortKey < b.card.sortKey
        }
    }

    private func ownedCopies(for item: CardItem) -> Int {
        ownedByKey[item.oracleID ?? item.scryfallID] ?? 0
    }

    /// The plan's list, with a card the user just put in kept in its place
    /// as a stepper, so the list doesn't jump under a tap.
    private func mergeRecommendations() {
        let recs = analysis.plan?.recommendations ?? []
        var merged = recs
        let ids = Set(recs.map(\.id))
        for (i, old) in recommendedShown.enumerated()
        where !ids.contains(old.id) && session.touched.contains(DeckAddSession.key(of: old.card)) {
            merged.insert(old, at: min(i, merged.count))
        }
        recommendedShown = merged
        if scope == .recommended { runSearch(immediately: true) }
    }

    private func loadDeck() async {
        let store = DeckStore.shared(for: modelContext.container)
        if let fetched = try? await store.snapshot(deckID: deckID), !Task.isCancelled {
            snapshot = fetched
            session.update(from: fetched)
            analysis.refresh(snapshot: fetched, container: modelContext.container)
            mergeRecommendations()
        }
    }

    private func loadOwned() async {
        // CollectionStore's rows for this stamp — usually already built by
        // the Collections tab — rather than a fresh read of the collection.
        let store = CollectionStore.shared(for: modelContext.container)
        if let cards = try? await store.ownedCards(stamp: .current), !Task.isCancelled {
            let (list, byKey, ids) = await Task.detached(priority: .userInitiated) { () -> (CardItemList, [String: Int], Set<String>) in
                var byKey: [String: Int] = [:]
                for card in cards { byKey[card.oracleID ?? card.scryfallID, default: 0] += card.quantity }
                return (CardItemList(cards), byKey, Set(cards.map(\.scryfallID)))
            }.value
            owned = list
            ownedByKey = byKey
            controller.updateOwned(ids)
        }
        ownedLoaded = true
        runSearch(immediately: true)
    }

    // MARK: Actions

    private func isOffIdentity(_ item: CardItem) -> Bool {
        usesIdentity && !Set(item.colorIdentity).isSubset(of: Set(identity))
    }

    /// Would putting `delta` more copies of `item` on `board` break a rule
    /// of the format? Decided before the write, from the snapshot in hand,
    /// so the haptic can answer the tap itself.
    private func breaksRule(adding item: CardItem, to board: DeckBoard, delta: Int) -> Bool {
        guard delta > 0, let snapshot, board.isPlayed else { return false }
        if isOffIdentity(item) { return true }
        if let target = snapshot.format.cardTarget, snapshot.mainCopies + delta > target { return true }
        if let limit = DeckStats.copyLimit(for: item, format: snapshot.format),
           session.quantity(of: item) + delta > limit, board == session.board { return true }
        return false
    }

    private func add(_ item: CardItem, to board: DeckBoard) {
        do {
            lastAddBroke = breaksRule(adding: item, to: board, delta: 1)
            try session.add(item, to: board)
            addCount += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func setQuantity(_ item: CardItem, _ quantity: Int) {
        do {
            lastAddBroke = breaksRule(adding: item, to: session.board, delta: quantity - session.quantity(of: item))
            try session.setQuantity(item, quantity)
            addCount += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ item: CardItem) {
        let items: [CardItem]
        switch scope {
        case .all: items = ownedOnly ? collectionCards.items : controller.results
        case .recommended: items = synergyShown.items + recommended.items
        }
        viewer = CardViewerSession(items: items, currentID: item.id, deck: session)
    }
}

/// A card found in the collection by a deck's search.
nonisolated struct DeckSearchResult: Identifiable, Hashable, Sendable {
    let card: CardItem
    let ownedCopies: Int
    var id: String { card.oracleID ?? card.scryfallID }
}
