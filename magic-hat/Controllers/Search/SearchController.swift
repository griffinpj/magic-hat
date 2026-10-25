//
//  SearchController.swift
//  magic-hat
//
//  Runs a CardSearchQuery against Scryfall and holds the results as
//  [CardItem] — the same value type the collection grid, viewer and detail
//  screen take, so search results get the whole card UI for free.
//
//  Host-agnostic on purpose: it knows nothing about the Search tab. Any
//  screen that later adds `.searchable` can own one of these, hand its
//  results to CardGridView, and present SearchFiltersView on its `query`.
//
//  Pages load as the grid nears the end (`loadMore(near:)`); mapping
//  Scryfall cards to CardItems runs off the main actor. Ownership is
//  layered on afterwards from CollectionStore so results show which cards
//  are already in a collection.
//

import Foundation
import Observation

@MainActor
@Observable
final class SearchController {
    enum Phase: Equatable {
        case idle
        case searching
        case results
        case empty
        case failed(String)
    }

    /// What the filter sheet edits and the search field types into.
    var query = CardSearchQuery()

    private(set) var phase: Phase = .idle
    private(set) var results: [CardItem] = [] {
        didSet {
            resultList = CardItemList(results)
            foldedNames = nil
        }
    }
    /// The distinct names of the first results, each with its folded form
    /// (case and diacritics), made once per results rather than a
    /// locale-aware `range(of:options:)` per name per render.
    @ObservationIgnored private var foldedNames: [(name: String, folded: String)]?
    /// `results` for the grid: stamped, so the grid's input compare is one
    /// integer rather than every card (see CardItemList).
    private(set) var resultList = CardItemList()
    private(set) var totalCards: Int?
    private(set) var isLoadingMore = false
    /// A new first page is loading while the previous results stay on
    /// screen (live typing). The spinner shows only when there is nothing
    /// to keep.
    private(set) var isRefreshing = false
    /// The query the current results answer. The Filters button counts
    /// this one, and `run()` is a no-op while `query` still equals it.
    private(set) var appliedQuery: CardSearchQuery?

    private var nextPage: URL?
    /// What the collection owns, for marking hits (and, with Group
    /// Printings on, swapping a hit to the printing owned).
    private var ownership: OwnedIndex?
    private var searchTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    /// Bumped per run(); a page from an older run is dropped even if its
    /// request finished after the newer one's.
    private var generation = 0
    private let client: any CardSearching

    /// How close to the end of the loaded results the grid gets before the
    /// next page is requested.
    private let pageLookahead = 40

    init(client: any CardSearching = ScryfallClient.shared) {
        self.client = client
    }

    var hasResults: Bool { !results.isEmpty }

    /// Distinct card names in the results that contain `text`, prefix
    /// matches first, at most `limit` — the field's completions, which obey
    /// the filters because they come from the results. The first 200
    /// results are folded once; each keystroke is plain `hasPrefix` /
    /// `contains` on them.
    func completions(for text: String, limit: Int = 8) -> [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !t.contains(":") else { return [] }
        let needle = Self.fold(t)
        if foldedNames == nil {
            var seen = Set<String>()
            foldedNames = results.prefix(200).compactMap { item in
                seen.insert(item.name).inserted ? (item.name, Self.fold(item.name)) : nil
            }
        }
        var prefix: [String] = [], contains: [String] = []
        for (name, folded) in foldedNames ?? [] where folded != needle {
            if folded.hasPrefix(needle) {
                prefix.append(name)
            } else if folded.contains(needle) {
                contains.append(name)
            }
        }
        return Array((prefix + contains).prefix(limit))
    }

    private nonisolated static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Running

    /// Runs `query` from the first page, cancelling anything in flight.
    /// Existing results stay visible until the new page lands. An empty
    /// query clears to idle.
    func run() {
        debounceTask?.cancel()
        searchTask?.cancel()
        moreTask?.cancel()
        isLoadingMore = false

        guard !query.isEmpty else {
            clear()
            return
        }
        let q = query
        appliedQuery = q
        generation += 1
        let gen = generation
        nextPage = nil
        if results.isEmpty {
            phase = .searching
            totalCards = nil
        } else {
            isRefreshing = true
        }

        searchTask = Task { [client] in
            do {
                let page = try await client.search(
                    query: q.scryfallQuery, unique: q.unique,
                    order: q.sort.scryfallOrder, direction: q.effectiveDirection.rawValue
                )
                guard !Task.isCancelled, gen == generation else { return }
                apply(page, replacing: true, generation: gen)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, gen == generation else { return }
                isRefreshing = false
                results = []
                phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Runs after a short pause in typing, if the query changed.
    func scheduleRun(after delay: Duration = .milliseconds(350)) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            runIfChanged()
        }
    }

    /// Sets the search text after a pause in typing, then runs if it
    /// changed. Keeping the text out of `query` until then means views
    /// observing the query (the filter form) don't re-render per keystroke.
    func scheduleText(_ text: String, after delay: Duration = .milliseconds(350)) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            query.text = text
            runIfChanged()
        }
    }

    /// Re-runs only if the query changed since the results were fetched.
    func runIfChanged() {
        guard query != appliedQuery else { return }
        run()
    }

    func clear() {
        debounceTask?.cancel()
        searchTask?.cancel()
        moreTask?.cancel()
        generation += 1
        results = []
        totalCards = nil
        nextPage = nil
        appliedQuery = nil
        isLoadingMore = false
        isRefreshing = false
        phase = .idle
    }

    /// Requests the next page once the grid shows a tile near the end.
    func loadMore(near index: Int) {
        guard let next = nextPage, !isLoadingMore, phase == .results,
              index >= results.count - pageLookahead else { return }
        isLoadingMore = true
        let gen = generation
        moreTask = Task { [client] in
            do {
                let page = try await client.search(pageURL: next)
                guard !Task.isCancelled, gen == generation else { isLoadingMore = false; return }
                // `finish` clears isLoadingMore once the page is appended.
                apply(page, replacing: false, generation: gen)
            } catch {
                // Keep what we have; the next scroll retries.
                isLoadingMore = false
                guard !Task.isCancelled else { return }
                nextPage = next
            }
        }
    }

    /// Marks results that are in a collection. Called by the host when its
    /// store's owned set changes (initial load, after add/remove).
    func updateOwned(_ ids: Set<String>) {
        updateOwned(OwnedIndex(scryfallIDs: ids, copiesByKey: [:], ownedPrintingIDs: ids))
    }

    /// Marks results from the collection's index: owned, the decks each
    /// is in, and — when the results group printings — the owned printing
    /// shown in place of Scryfall's. A hit swapped this way changes id,
    /// so the results are re-stamped as a new list.
    func updateOwned(_ index: OwnedIndex) {
        if let stamp = index.stamp, stamp == ownership?.stamp { return }
        ownership = index
        guard !results.isEmpty else { return }
        let grouped = appliedQuery?.groupPrintings ?? false
        var seen = Set<String>()
        results = results.compactMap { item in
            let marked = index.mark(item, groupedPrintings: grouped)
            return seen.insert(marked.id).inserted ? marked : nil
        }
    }

    // MARK: Internals

    private func apply(_ page: ScryfallSearchPage, replacing: Bool, generation gen: Int) {
        let owned = ownership
        let grouped = appliedQuery?.groupPrintings ?? false
        let cards = page.cards
        Task.detached(priority: .userInitiated) {
            let items = cards.map { card in
                let item = CardItem(scryfallCard: card, owned: false)
                return owned?.mark(item, groupedPrintings: grouped) ?? item
            }
            await MainActor.run {
                // The mapping isn't linked to the search task, so check the
                // generation here too: a newer run may have started meanwhile.
                guard gen == self.generation else { return }
                self.finish(items, page: page, replacing: replacing)
            }
        }
    }

    private func finish(_ items: [CardItem], page: ScryfallSearchPage, replacing: Bool) {
        isRefreshing = false
        if replacing {
            results = items
        } else {
            // A page can overlap the previous one if Scryfall's data moved
            // between requests; keep ids unique so the grid never sees a
            // duplicate identifier.
            let seen = Set(results.map(\.id))
            results.append(contentsOf: items.filter { !seen.contains($0.id) })
        }
        totalCards = page.totalCards ?? (page.nextPage == nil ? results.count : nil)
        nextPage = page.nextPage
        phase = results.isEmpty ? .empty : .results
        isLoadingMore = false
    }

    private static func message(for error: Error) -> String {
        if let http = error as? HTTPError, case .badStatus(_, let data) = http,
           let body = try? JSONDecoder().decode(ScryfallErrorBody.self, from: data) {
            return body.details
        }
        return error.localizedDescription
    }
}

/// Scryfall's error envelope: `{ "object": "error", "details": "…" }`.
nonisolated struct ScryfallErrorBody: Decodable {
    let details: String
}

extension CardItem {
    /// The same card with `owned` changed.
    nonisolated func withOwned(_ owned: Bool) -> CardItem {
        var copy = self
        copy.owned = owned
        return copy
    }
}
