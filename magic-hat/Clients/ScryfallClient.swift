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

struct ScryfallClient {
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

extension Array {
    /// Splits the array into consecutive chunks of at most `size`.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
