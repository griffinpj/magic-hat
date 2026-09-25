//
//  RecommanderClient.swift
//  magic-hat
//
//  Recommander (recommander.cards): given a commander and the list so
//  far, the cards the wider meta plays with it, each with a co-occurrence
//  score (0–1). Good at catching an overlooked staple, blind to rules
//  traps and deliberate off-meta builds — so the analysis folds it into
//  the ranking rather than taking it as the answer. No key, no auth.
//

import Foundation

nonisolated struct RecommanderCard: Codable, Sendable, Hashable {
    let oracleID: String
    let name: String
    let score: Double

    enum CodingKeys: String, CodingKey {
        case oracleID = "oracle_id"
        case name, score
    }
}

nonisolated struct RecommanderResponse: Codable, Sendable {
    struct Payload: Codable, Sendable {
        let recommendations: [RecommanderCard]
    }
    let resultCode: String
    let data: Payload?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case resultCode = "result_code"
        case data, error
    }
}

nonisolated struct RecommanderRequest: Codable, Sendable {
    let commander: String
    let partner: String?
    let deck: [String]
    let cardFormat: String

    enum CodingKeys: String, CodingKey {
        case commander, partner, deck
        case cardFormat = "card_format"
    }
}

nonisolated struct RecommanderClient {
    static let shared = RecommanderClient()

    private let baseURL = URL(string: "https://api.recommander.cards/public-release/api")!
    private let http: HTTPClient

    init(http: HTTPClient = HTTPClient(userAgent: "MagicHat/1.0")) {
        self.http = http
    }

    /// POST /decks/recommend/top — the meta's picks for this commander
    /// given the list. `deck` is card names (the commander excluded).
    func recommend(commander: String, partner: String? = nil, deck: [String]) async throws -> [RecommanderCard] {
        let body = RecommanderRequest(commander: commander, partner: partner, deck: Array(Set(deck)).sorted(), cardFormat: "name")
        let data = try JSONEncoder().encode(body)
        let url = baseURL.appendingPathComponent("decks").appendingPathComponent("recommend").appendingPathComponent("top")
        let response = try await http.request(RecommanderResponse.self, url: url, method: .post, body: data, rateLimit: .recommander)
        guard response.resultCode == "success", let payload = response.data else {
            throw RecommanderError.failed(response.error ?? response.resultCode)
        }
        return payload.recommendations
    }
}

enum RecommanderError: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case .failed(let s) = self { return "Recommander: \(s)" }
        return nil
    }
}
