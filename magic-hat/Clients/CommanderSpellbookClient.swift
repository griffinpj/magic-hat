//
//  CommanderSpellbookClient.swift
//  magic-hat
//
//  Commander Spellbook (commanderspellbook.com), the community's combo
//  database. Two calls: `find-my-combos`, which takes a whole list and
//  answers with the combos it contains and the ones it is one card short
//  of — what the Bracket rating and the swap table read — and the variant
//  search, which lists every combo a single card is part of, for the
//  card's Synergies screen. No key, no auth. Endpoint shapes only; the
//  transport is HTTPClient.
//
//  API: https://backend.commanderspellbook.com/
//

import Foundation

nonisolated struct SpellbookCard: Codable, Sendable, Hashable {
    let id: Int?
    let name: String
    let oracleId: String?
    let typeLine: String?
    let imageUriFrontNormal: String?
    let imageUriFrontArtCrop: String?
}

nonisolated struct SpellbookUse: Codable, Sendable, Hashable {
    let card: SpellbookCard
    let quantity: Int?
    let mustBeCommander: Bool?
}

nonisolated struct SpellbookFeature: Codable, Sendable, Hashable {
    let name: String
}

nonisolated struct SpellbookProduce: Codable, Sendable, Hashable {
    let feature: SpellbookFeature
}

/// One combo ("variant"): the cards it uses and what it produces.
nonisolated struct SpellbookVariant: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let uses: [SpellbookUse]
    let produces: [SpellbookProduce]?
    let identity: String?
    let popularity: Int?
    let bracketTag: String?
    let manaNeeded: String?
    let manaValueNeeded: Int?
    let status: String?
    let description: String?
    let legalities: [String: Bool]?

    var cardNames: [String] { uses.map(\.card.name) }
    var results: [String] { (produces ?? []).map(\.feature.name) }
}

nonisolated struct SpellbookFindResults: Codable, Sendable {
    let identity: String?
    let included: [SpellbookVariant]
    let almostIncluded: [SpellbookVariant]?
    let almostIncludedByAddingColors: [SpellbookVariant]?
}

nonisolated struct SpellbookFindResponse: Codable, Sendable {
    let results: SpellbookFindResults
}

nonisolated struct SpellbookVariantPage: Codable, Sendable {
    let count: Int?
    let next: String?
    let results: [SpellbookVariant]
}

nonisolated struct SpellbookDeckEntry: Codable, Sendable {
    let card: String
    let quantity: Int
}

nonisolated struct SpellbookFindRequest: Codable, Sendable {
    let commanders: [SpellbookDeckEntry]
    let main: [SpellbookDeckEntry]
}

nonisolated extension DeckCombo {
    init(_ v: SpellbookVariant) {
        self.init(id: v.id, cards: v.cardNames, produces: Array(v.results.prefix(3)), bracketTag: v.bracketTag ?? "",
                  manaNeeded: v.manaNeeded ?? "", popularity: v.popularity ?? 0, missing: nil)
    }
}

nonisolated struct CommanderSpellbookClient {
    static let shared = CommanderSpellbookClient()

    private let baseURL = URL(string: "https://backend.commanderspellbook.com")!
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// POST /find-my-combos — the combos in a list, and the ones it is a
    /// card short of.
    func findCombos(commanders: [String], main: [(name: String, quantity: Int)]) async throws -> SpellbookFindResults {
        let body = SpellbookFindRequest(
            commanders: commanders.map { SpellbookDeckEntry(card: $0, quantity: 1) },
            main: main.map { SpellbookDeckEntry(card: $0.name, quantity: $0.quantity) }
        )
        let data = try JSONEncoder().encode(body)
        let url = baseURL.appendingPathComponent("find-my-combos")
        return try await http.request(SpellbookFindResponse.self, url: url, method: .post, body: data, rateLimit: .spellbook).results
    }

    /// GET /variants/?q=card:"Name" — every combo the card is part of,
    /// most played first.
    func variants(using cardName: String, limit: Int = 30) async throws -> [SpellbookVariant] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("variants/"), resolvingAgainstBaseURL: false)!
        let quoted = cardName.replacingOccurrences(of: "\"", with: "")
        comps.queryItems = [
            URLQueryItem(name: "q", value: "card:\"\(quoted)\""),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "ordering", value: "-popularity"),
        ]
        guard let url = comps.url else { throw HTTPError.badURL }
        return try await http.request(SpellbookVariantPage.self, url: url, rateLimit: .spellbook).results
    }

    /// The find-my-combos answer as the analysis reads it: included combos
    /// and, of the near misses, the ones exactly one card short of a list
    /// of `have` (front-face names, lowercased).
    static func comboSet(_ results: SpellbookFindResults, have: Set<String>) -> DeckComboSet {
        let included = results.included.map(DeckCombo.init)
        var near: [DeckCombo] = []
        for v in results.almostIncluded ?? [] {
            var combo = DeckCombo(v)
            let missing = combo.cards.filter { !have.contains(CardReading.frontName($0)) }
            guard missing.count == 1, combo.cards.count <= 3 else { continue }
            combo.missing = missing[0]
            near.append(combo)
        }
        near.sort { $0.popularity > $1.popularity }
        return DeckComboSet(included: included, near: Array(near.prefix(40)))
    }
}
