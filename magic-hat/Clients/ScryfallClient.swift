//
//  ScryfallClient.swift
//  magic-hat
//
//  Client for the Scryfall card API. Responsible only for describing
//  endpoints and shaping requests/responses; transport, headers, and rate
//  limiting live in HTTPClient / RateLimiter.
//
//  API docs: https://scryfall.com/docs/api/cards
//

import Foundation

/// The two calls a search needs. SearchController depends on this rather
/// than on ScryfallClient so tests can feed it pages without a network.
nonisolated protocol CardSearching {
    func search(query: String, unique: String, order: String, direction: String) async throws -> ScryfallSearchPage
    func search(pageURL: URL) async throws -> ScryfallSearchPage
}

nonisolated struct ScryfallClient: CardSearching {
    static let shared = ScryfallClient()

    private let baseURL = URL(string: "https://api.scryfall.com")!
    private let http: HTTPClient

    /// Max identifiers Scryfall accepts per /cards/collection request.
    static let collectionBatchSize = 75

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// GET /cards/:id — a single card by Scryfall ID.
    func card(id: String) async throws -> ScryfallCard {
        let url = baseURL.appendingPathComponent("cards").appendingPathComponent(id)
        return try await http.request(
            ScryfallCard.self, url: url, rateLimit: .other
        )
    }

    /// GET /sets/:code — set metadata, including the SVG set-symbol URI.
    func set(code: String) async throws -> ScryfallSet {
        let url = baseURL.appendingPathComponent("sets")
            .appendingPathComponent(code.lowercased())
        return try await http.request(ScryfallSet.self, url: url, rateLimit: .other)
    }

    /// GET /cards/search — all printings of a card, by oracle id, newest first.
    /// Rate limited to 2/sec; follows pagination.
    func printings(oracleID: String) async throws -> [ScryfallCard] {
        var results: [ScryfallCard] = []
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("cards").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "q", value: "oracleid:\(oracleID)"),
            URLQueryItem(name: "unique", value: "prints"),
            URLQueryItem(name: "order", value: "released"),
            URLQueryItem(name: "dir", value: "desc")
        ]
        var nextURL = comps.url

        while let url = nextURL {
            let page = try await http.request(
                ScryfallListResponse.self, url: url, rateLimit: .cardsSearch
            )
            results.append(contentsOf: page.data)
            if page.hasMore == true, let next = page.nextPage {
                nextURL = URL(string: next)
            } else {
                nextURL = nil
            }
        }
        return results
    }

    /// GET /cards/search — a full-text search, first page. `q` is Scryfall
    /// syntax (see CardSearchQuery.scryfallQuery). Scryfall answers "no
    /// cards matched" with a 404, which is a result, not an error.
    func search(query: String, unique: String, order: String, direction: String) async throws -> ScryfallSearchPage {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("cards").appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "unique", value: unique),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "dir", value: direction),
        ]
        guard let url = comps.url else { throw HTTPError.badURL }
        return try await search(pageURL: url)
    }

    /// GET a search page by its URL (the first, or a `next_page`).
    func search(pageURL: URL) async throws -> ScryfallSearchPage {
        do {
            let page = try await http.request(ScryfallListResponse.self, url: pageURL, rateLimit: .cardsSearch)
            let next = (page.hasMore == true) ? page.nextPage.flatMap(URL.init(string:)) : nil
            return ScryfallSearchPage(cards: page.data, totalCards: page.totalCards, nextPage: next)
        } catch HTTPError.badStatus(404, _) {
            return .empty
        }
    }

    /// GET /cards/autocomplete — up to 20 card names starting with `q`.
    func autocomplete(_ q: String) async throws -> [String] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("cards").appendingPathComponent("autocomplete"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        guard let url = comps.url else { throw HTTPError.badURL }
        return try await http.request(ScryfallStringListResponse.self, url: url, rateLimit: .other).data
    }

    /// GET /catalog/:name — a vocabulary list (creature types, artists, …).
    func catalog(_ name: String) async throws -> [String] {
        let url = baseURL.appendingPathComponent("catalog").appendingPathComponent(name)
        return try await http.request(ScryfallStringListResponse.self, url: url, rateLimit: .other).data
    }

    /// GET /sets — every set, newest first (~600KB).
    func sets() async throws -> [ScryfallSet] {
        let url = baseURL.appendingPathComponent("sets")
        return try await http.request(ScryfallSetListResponse.self, url: url, rateLimit: .other).data
    }

    /// POST /cards/collection — up to 75 cards in one request by ID.
    /// Rate limited to 2/sec. Callers should chunk large lists themselves
    /// or use `cards(ids:)` which chunks automatically.
    func collection(ids: [String]) async throws -> ScryfallCollectionResponse {
        let url = baseURL.appendingPathComponent("cards").appendingPathComponent("collection")
        let body = ScryfallCollectionRequest(
            identifiers: ids.map { ScryfallCardIdentifier(id: $0) }
        )
        let data = try JSONEncoder().encode(body)
        return try await http.request(
            ScryfallCollectionResponse.self,
            url: url,
            method: .post,
            body: data,
            rateLimit: .cardsCollection
        )
    }

    /// POST /cards/collection with arbitrary identifiers (name, or set +
    /// number) — how an imported deck list's unknown cards are looked up.
    func collection(identifiers: [ScryfallCardIdentifier]) async throws -> ScryfallCollectionResponse {
        let url = baseURL.appendingPathComponent("cards").appendingPathComponent("collection")
        let data = try JSONEncoder().encode(ScryfallCollectionRequest(identifiers: identifiers))
        return try await http.request(
            ScryfallCollectionResponse.self, url: url, method: .post, body: data, rateLimit: .cardsCollection
        )
    }

    /// Fetches metadata for many cards, chunking into batches of 75 and
    /// pacing via the collection rate limit. Returns all found cards.
    func cards(ids: [String]) async throws -> [ScryfallCard] {
        var results: [ScryfallCard] = []
        for chunk in ids.chunked(into: Self.collectionBatchSize) {
            let response = try await collection(ids: chunk)
            results.append(contentsOf: response.data)
        }
        return results
    }
}

nonisolated extension Array {
    /// Splits the array into consecutive chunks of at most `size`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// MARK: - Oracle lists

nonisolated extension ScryfallClient {
    /// One page of a search, keyed for the analysis: oracle id → name.
    struct OracleIndexPage: Sendable {
        let index: [String: String]
        let next: URL?
    }

    /// GET /cards/search, `unique:cards`, up to `maxPages` pages from the
    /// first page or from `resume` (a `next_page` URL kept from an earlier
    /// call). The analysis keeps Scryfall's oracle-tag lists (`otag:ramp`,
    /// `is:gamechanger`) this way, a few pages per sitting, so a long list
    /// never sits in the search rate limit ahead of the user's own search.
    func oracleIndex(query: String, maxPages: Int, resume: URL? = nil) async throws -> OracleIndexPage {
        var index: [String: String] = [:]
        var nextURL: URL?
        if let resume {
            nextURL = resume
        } else {
            var comps = URLComponents(url: baseURL.appendingPathComponent("cards").appendingPathComponent("search"),
                                      resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "unique", value: "cards"),
                URLQueryItem(name: "order", value: "name"),
            ]
            nextURL = comps.url
        }
        var pages = 0
        while let url = nextURL, pages < maxPages {
            let page: ScryfallListResponse
            do {
                page = try await http.request(ScryfallListResponse.self, url: url, rateLimit: .cardsSearch)
            } catch HTTPError.badStatus(404, _) {
                return OracleIndexPage(index: index, next: nil)   // no matches is an empty list
            }
            for card in page.data { if let oracle = card.bestOracleID { index[oracle] = card.name } }
            pages += 1
            nextURL = page.hasMore == true ? page.nextPage.flatMap(URL.init(string:)) : nil
        }
        return OracleIndexPage(index: index, next: nextURL)
    }
}
