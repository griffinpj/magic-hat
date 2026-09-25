//
//  EDHRECClient.swift
//  magic-hat
//
//  EDHREC's page data (json.edhrec.com): for a card, the cards that show
//  up in decks with it more than chance would have them (`lift`), and
//  for a commander its high-synergy cards (`synergy`), inclusion counts
//  and salt. This is the JSON behind the website rather than a published
//  API, so every field is optional, an unknown card answers 403, and a
//  page that fails to decode means "no EDHREC data", never an error the
//  user sees. Cached a week (Utils/DiskJSONCache) so a card is asked for
//  once. No key, no auth.
//

import Foundation

nonisolated struct EDHRECCardView: Codable, Sendable, Hashable, Identifiable {
    /// Scryfall id of the printing EDHREC shows.
    let id: String?
    let name: String
    let sanitized: String?
    /// Commander pages: how much more often the card is played with this
    /// commander than with others (0.27 = 27% more).
    let synergy: Double?
    /// Card pages: decks with both over what chance would give (>1 is more).
    let lift: Double?
    let numDecks: Int?
    let potentialDecks: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, sanitized, synergy, lift
        case numDecks = "num_decks"
        case potentialDecks = "potential_decks"
    }

    /// Share of eligible decks running it, 0–1.
    var inclusion: Double? {
        guard let numDecks, let potentialDecks, potentialDecks > 0 else { return nil }
        return Double(numDecks) / Double(potentialDecks)
    }
}

nonisolated struct EDHRECCardList: Codable, Sendable, Hashable {
    let header: String?
    let tag: String?
    let cardviews: [EDHRECCardView]
}

nonisolated struct EDHRECCardInfo: Codable, Sendable, Hashable {
    let id: String?
    let name: String?
    let numDecks: Int?
    let potentialDecks: Int?
    let salt: Double?
    let rank: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, salt, rank
        case numDecks = "num_decks"
        case potentialDecks = "potential_decks"
    }

    var inclusion: Double? {
        guard let numDecks, let potentialDecks, potentialDecks > 0 else { return nil }
        return Double(numDecks) / Double(potentialDecks)
    }
}

nonisolated struct EDHRECPage: Codable, Sendable, Hashable {
    struct Container: Codable, Sendable, Hashable {
        let jsonDict: JSONDict
        enum CodingKeys: String, CodingKey { case jsonDict = "json_dict" }
    }
    struct JSONDict: Codable, Sendable, Hashable {
        let card: EDHRECCardInfo?
        let cardlists: [EDHRECCardList]?
    }
    let container: Container

    var card: EDHRECCardInfo? { container.jsonDict.card }
    var cardlists: [EDHRECCardList] { container.jsonDict.cardlists ?? [] }
    /// True for a commander page (synergy scores), false for a card page (lift).
    var hasSynergy: Bool { cardlists.contains { $0.cardviews.contains { $0.synergy != nil } } }
}

nonisolated struct EDHRECClient {
    static let shared = EDHRECClient()

    private let baseURL = URL(string: "https://json.edhrec.com/pages")!
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// GET /pages/cards/<slug>.json — the card's page.
    func cardPage(slug: String) async throws -> EDHRECPage {
        try await page(kind: "cards", slug: slug)
    }

    /// GET /pages/commanders/<slug>.json — the card as a commander: its
    /// high-synergy cards. 403 when the card has never led a deck.
    func commanderPage(slug: String) async throws -> EDHRECPage {
        try await page(kind: "commanders", slug: slug)
    }

    private func page(kind: String, slug: String) async throws -> EDHRECPage {
        let url = baseURL.appendingPathComponent(kind).appendingPathComponent("\(slug).json")
        return try await http.request(EDHRECPage.self, url: url, rateLimit: .edhrec)
    }

    /// EDHREC's slug for a card name: the front face, lowercased, ASCII,
    /// punctuation dropped, spaces to hyphens ("Atraxa, Praetors' Voice"
    /// → "atraxa-praetors-voice").
    static func slug(for name: String) -> String {
        let front = name.components(separatedBy: " // ").first ?? name
        var s = front.lowercased()
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "œ", with: "oe")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        s = s.map { ch -> Character in
            if ch.isLetter || ch.isNumber { return ch }
            if ch == " " || ch == "-" { return "-" }
            return "\u{0}"
        }.filter { $0 != "\u{0}" }.reduce(into: "") { out, ch in
            if ch == "-", out.last == "-" { return }
            out.append(ch)
        }
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }
}
