//
//  MTGJSONClient.swift
//  magic-hat
//
//  Client for the MTGJSON v5 bulk API. Like ScryfallClient it only describes
//  endpoints and shapes; transport, headers and pacing live in HTTPClient /
//  RateLimiter.
//
//  MTGJSON publishes static files from a CDN rather than a per-card API, so
//  the useful calls are "one set" (a few MB) and "today's prices for every
//  card" (large — treat as a deliberate, user-initiated download, never as
//  something that happens while scrolling).
//

import Foundation

nonisolated struct MTGJSONClient {
    static let shared = MTGJSONClient()

    private let baseURL = URL(string: "https://mtgjson.com/api/v5")!
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// GET /api/v5/<SET>.json — one set, including the Scryfall id for each
    /// card (the bridge between MTGJSON UUIDs and everything else we store).
    func set(code: String) async throws -> MTGJSONSet {
        let url = baseURL.appendingPathComponent("\(code.uppercased()).json")
        // Static CDN file, not a rate-limited card endpoint.
        return try await http.request(
            MTGJSONSetResponse.self, url: url, rateLimit: .other
        ).data
    }

    /// Maps Scryfall id -> MTGJSON uuid for a set. Prices are keyed by uuid,
    /// so this is required before any price lookup can be joined to our cards.
    func scryfallToUUID(setCode: String) async throws -> [String: String] {
        let set = try await set(code: setCode)
        var map: [String: String] = [:]
        for card in set.cards {
            if let scryfallID = card.identifiers.scryfallId {
                map[scryfallID] = card.uuid
            }
        }
        return map
    }

    /// GET /api/v5/AllPricesToday.json — today's prices for every card, keyed
    /// by MTGJSON uuid.
    ///
    /// 5.2MB gzipped, 53MB decoded, ~660MB peak RSS to parse whole. Intended
    /// for a server-side job; parsing this on device will get the app killed.
    func pricesToday() async throws -> [String: MTGJSONCardPrices] {
        let url = baseURL.appendingPathComponent("AllPricesToday.json")
        return try await http.request(
            MTGJSONPricesResponse.self, url: url, rateLimit: .other
        ).data
    }

    /// Flattens one card's provider prices into the app's quote shape.
    /// Note this yields retail + buylist, not low/mid/market — MTGJSON does
    /// not publish tiers (verified against AllPricesToday).
    nonisolated static func quote(
        from prices: MTGJSONCardPrices,
        foil: Bool,
        preferring provider: String = "tcgplayer"
    ) -> CardPriceQuote? {
        guard let paper = prices.paper, !paper.isEmpty else { return nil }
        let chosen = paper[provider] ?? paper.values.first
        guard let chosen, let retail = chosen.retail else { return nil }

        return CardPriceQuote(
            retail: retail.latest(foil: foil),
            buylist: chosen.buylist?.latest(foil: foil),
            vendor: provider,
            currency: chosen.currency ?? "USD"
        )
    }
}
