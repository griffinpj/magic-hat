import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// Feeds SearchController canned pages; no network.
@MainActor
final class FakeSearchClient: CardSearching {
    var pages: [ScryfallSearchPage] = []
    var error: Error?
    private(set) var queries: [String] = []
    private(set) var pageURLs: [URL] = []

    func search(query: String, unique: String, order: String, direction: String) async throws -> ScryfallSearchPage {
        queries.append(query)
        if let error { throw error }
        return pages.first ?? .empty
    }

    func search(pageURL: URL) async throws -> ScryfallSearchPage {
        pageURLs.append(pageURL)
        if let error { throw error }
        return pages.count > 1 ? pages[1] : .empty
    }
}

@MainActor
@Suite("SearchController")
struct SearchControllerTests {
    static func card(_ id: String, name: String = "Card") throws -> ScryfallCard {
        let json = """
        {"id":"\(id)","name":"\(name)","set":"tst","set_name":"Test","collector_number":"1","rarity":"rare"}
        """
        return try JSONDecoder().decode(ScryfallCard.self, from: Data(json.utf8))
    }

    static func settle(_ c: SearchController, timeout: Duration = .seconds(2)) async {
        let start = ContinuousClock.now
        while c.phase == .searching || c.isLoadingMore || c.isRefreshing, ContinuousClock.now - start < timeout {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func emptyQueryStaysIdle() async {
        let client = FakeSearchClient()
        let c = SearchController(client: client)
        c.run()
        await Self.settle(c)
        #expect(c.phase == .idle)
        #expect(client.queries.isEmpty)
    }

    @Test func runProducesResultsAndPagesOnDemand() async throws {
        let client = FakeSearchClient()
        let next = URL(string: "https://api.scryfall.com/cards/search?page=2")!
        // 50 on the first page: more than the 40-tile lookahead, so the top
        // of the grid must not trigger paging but the tail must.
        let first = try (0..<50).map { try Self.card("a\($0)") }
        client.pages = [
            ScryfallSearchPage(cards: first, totalCards: 52, nextPage: next),
            ScryfallSearchPage(cards: try [Self.card("a49"), Self.card("b0"), Self.card("b1")], totalCards: 52, nextPage: nil),
        ]
        let c = SearchController(client: client)
        c.query.text = "dragon"
        c.query.formats = [.modern]
        c.run()
        await Self.settle(c)
        #expect(c.phase == .results)
        #expect(c.results.count == 50)
        #expect(c.totalCards == 52)
        #expect(client.queries.first?.contains("legal:modern") == true)
        #expect(c.appliedQuery == c.query)

        // Far from the end: nothing happens.
        c.loadMore(near: 0)
        #expect(!c.isLoadingMore)
        #expect(client.pageURLs.isEmpty)
        // Within the lookahead: the next page loads and the overlapping id
        // (Scryfall's data can shift between requests) is dropped.
        c.loadMore(near: 12)
        #expect(c.isLoadingMore)
        await Self.settle(c)
        #expect(client.pageURLs == [next])
        #expect(c.results.count == 52)
        #expect(c.results.suffix(3).map(\.id) == ["a49", "b0", "b1"])
        #expect(Set(c.results.map(\.id)).count == 52, "no duplicate ids")
        // No further page.
        c.loadMore(near: 51)
        #expect(!c.isLoadingMore)
    }

    @Test func noMatchesIsEmptyNotAnError() async {
        let client = FakeSearchClient()
        client.pages = [.empty]
        let c = SearchController(client: client)
        c.query.text = "zzzz"
        c.run()
        await Self.settle(c)
        #expect(c.phase == .empty)
    }

    @Test func transportErrorIsSurfaced() async {
        let client = FakeSearchClient()
        client.error = HTTPError.transport(URLError(.notConnectedToInternet))
        let c = SearchController(client: client)
        c.query.text = "x"
        c.run()
        await Self.settle(c)
        guard case .failed = c.phase else { Issue.record("expected failed, got \(c.phase)"); return }
    }

    @Test func scryfallErrorDetailsAreUsed() async {
        let client = FakeSearchClient()
        let body = Data(#"{"object":"error","code":"bad_request","details":"Invalid syntax"}"#.utf8)
        client.error = HTTPError.badStatus(400, body)
        let c = SearchController(client: client)
        c.query.text = "x"
        c.run()
        await Self.settle(c)
        #expect(c.phase == .failed("Invalid syntax"))
    }

    @Test func ownershipIsLayeredOntoResults() async throws {
        let client = FakeSearchClient()
        client.pages = [ScryfallSearchPage(cards: try [Self.card("a"), Self.card("b")], totalCards: 2, nextPage: nil)]
        let c = SearchController(client: client)
        c.updateOwned(["b"])
        c.query.text = "x"
        c.run()
        await Self.settle(c)
        #expect(c.results.map(\.owned) == [false, true])
        c.updateOwned(["a"])
        #expect(c.results.map(\.owned) == [true, false])
        #expect(c.results.allSatisfy { !$0.isEntry }, "search hits are never entries")
    }

    @Test func runIfChangedIsANoOpForTheSameQuery() async throws {
        let client = FakeSearchClient()
        client.pages = [ScryfallSearchPage(cards: try [Self.card("a")], totalCards: 1, nextPage: nil)]
        let c = SearchController(client: client)
        c.query.text = "x"
        c.run()
        await Self.settle(c)
        c.runIfChanged()
        await Self.settle(c)
        #expect(client.queries.count == 1)
        c.query.rarities = [.rare]
        c.runIfChanged()
        await Self.settle(c)
        #expect(client.queries.count == 2)
    }

    @Test func savedSearchRoundTripsInSwiftData() throws {
        let container = try TestSupport.makeContainer()
        let context = container.mainContext
        var q = CardSearchQuery()
        q.text = "dragon"
        q.colors = [.red]
        q.stats = [StatConstraint(.power, .greaterOrEqual, 5)]
        context.insert(SavedSearch(name: "Big red dragons", query: q, sortOrder: 3))
        try context.save()
        let fetched = try context.fetch(FetchDescriptor<SavedSearch>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.query == q)
        #expect(fetched.first?.sortOrder == 3)
        _ = container
    }
}

@MainActor
@Suite("SearchController live search")
struct SearchControllerLiveTests {
    @Test func rerunKeepsResultsUntilTheNewPageLands() async throws {
        let client = FakeSearchClient()
        client.pages = [ScryfallSearchPage(cards: try [SearchControllerTests.card("a")], totalCards: 1, nextPage: nil)]
        let c = SearchController(client: client)
        c.query.text = "a"
        c.run()
        await SearchControllerTests.settle(c)
        #expect(c.results.count == 1)

        c.query.text = "ab"
        c.run()
        // Synchronously after run(): old results still there, refreshing.
        #expect(c.phase == .results)
        #expect(c.results.count == 1)
        #expect(c.isRefreshing)
        while c.isRefreshing { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(client.queries.count == 2)
        #expect(!c.isRefreshing)
    }

    @Test func scheduleRunDebouncesAndRunsOnce() async throws {
        let client = FakeSearchClient()
        client.pages = [ScryfallSearchPage(cards: try [SearchControllerTests.card("a")], totalCards: 1, nextPage: nil)]
        let c = SearchController(client: client)
        for text in ["g", "gl", "gle", "glea"] {
            c.query.text = text
            c.scheduleRun(after: .milliseconds(30))
        }
        // Poll rather than sleep a fixed time: under a parallel test load
        // the debounce task can be scheduled late.
        let start = ContinuousClock.now
        while client.queries.isEmpty, ContinuousClock.now - start < .seconds(3) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await SearchControllerTests.settle(c)
        #expect(client.queries.count == 1, "one request for four keystrokes")
        #expect(client.queries.first?.hasPrefix("glea") == true)
        // Same query again: the debounced run is a no-op.
        c.scheduleRun(after: .milliseconds(10))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(client.queries.count == 1)
    }

    @Test func clearReturnsToIdleAndDropsPendingRun() async {
        let client = FakeSearchClient()
        let c = SearchController(client: client)
        c.query.text = "x"
        c.scheduleRun(after: .milliseconds(30))
        c.query.text = ""
        c.clear()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(c.phase == .idle)
        #expect(client.queries.isEmpty, "pending debounce cancelled")
    }
}
