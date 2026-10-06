//
//  MTGJSONModels.swift
//  magic-hat
//
//  Decodable shapes for the MTGJSON v5 bulk API (https://mtgjson.com/api/v5/).
//
//  What MTGJSON actually provides, measured rather than assumed: for each
//  card, per vendor (tcgplayer, cardkingdom, cardmarket, manapool,
//  cardhoarder), a single `retail` and a single `buylist` number per finish
//  per date. It does NOT publish low/mid/market tiers — those are TCGplayer's
//  own API, reachable directly via `CardMeta.tcgplayerID`.
//
//  MTGJSON's unique value is therefore buylist pricing (what a shop pays you)
//  and multi-vendor/multi-currency retail, neither of which Scryfall has.
//
//  Three constraints shape any use of it:
//   * Bulk-only — no "one card" endpoint; you fetch a set file or the whole
//     prices file.
//   * Prices are keyed by MTGJSON UUID, not Scryfall ID. Set files carry
//     `identifiers.scryfallId` (~1.1MB gzipped per set) to bridge them.
//   * `AllPricesToday.json` is 5.2MB gzipped but 53MB decompressed and peaks
//     around 660MB of RSS to parse whole — iOS would terminate the app. So
//     this client is intended for a server-side job, not the device.
//

import Foundation

// MARK: - Set files (per-set, a few MB)

/// Envelope for `/api/v5/<SET>.json`.
nonisolated struct MTGJSONSetResponse: Decodable, Sendable {
    let data: MTGJSONSet
}

nonisolated struct MTGJSONSet: Decodable, Sendable {
    let code: String
    let name: String
    let releaseDate: String?
    let cards: [MTGJSONCard]
}

nonisolated struct MTGJSONCard: Decodable, Sendable {
    let uuid: String
    let name: String
    let number: String?
    let rarity: String?
    let identifiers: MTGJSONIdentifiers
    let legalities: [String: String]?
    let edhrecRank: Int?
    let purchaseUrls: [String: String]?
}

nonisolated struct MTGJSONIdentifiers: Codable, Sendable {
    let scryfallId: String?
    var scryfallOracleId: String? = nil
    let tcgplayerProductId: String?
    let cardKingdomId: String?
    let mcmId: String?
}

// MARK: - Meta (113 bytes — cheap staleness check before any real download)

nonisolated struct MTGJSONMetaResponse: Decodable, Sendable {
    let data: MTGJSONMeta
}

nonisolated struct MTGJSONMeta: Decodable, Sendable {
    let date: String
    let version: String
}

// MARK: - Preconstructed decks

/// Entry in `/api/v5/DeckList.json` (634KB for all 3,000+ precons).
nonisolated struct MTGJSONDeckSummary: Codable, Sendable, Identifiable, Hashable {
    let code: String
    let fileName: String
    let name: String
    let releaseDate: String?
    let type: String?

    var id: String { fileName }
}

/// The kinds of preconstructed product the Decks tab offers, folding
/// MTGJSON's `type` strings (fifty-odd of them) into a handful a player
/// would look under. Measured against DeckList.json, 2026-10-05: 197
/// Commander Decks, 22 Challenger, 41 Planeswalker, 570 Jumpstart,
/// 761 Secret Lair Drops (not decks — left out of every kind but All).
nonisolated enum PreconKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case commander, standard, jumpstart, classic, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commander: return "Commander"
        case .standard: return "Challenger & Starter"
        case .jumpstart: return "Jumpstart"
        case .classic: return "Theme & Intro"
        case .all: return "Everything"
        }
    }

    func matches(_ type: String?) -> Bool {
        let t = (type ?? "").lowercased()
        switch self {
        case .commander: return t.contains("commander") || t.contains("brawl")
        case .standard: return t.contains("challenger") || t.contains("starter") || t.contains("planeswalker") || t.contains("event deck") || t.contains("welcome")
        case .jumpstart: return t.contains("jumpstart")
        case .classic: return t.contains("theme") || t.contains("intro") || t.contains("duel") || t.contains("premium") || t.contains("world championship") || t.contains("clash") || t.contains("archenemy") || t.contains("planechase")
        case .all: return !t.contains("secret lair")
        }
    }
}

nonisolated struct MTGJSONDeckListResponse: Decodable, Sendable {
    let data: [MTGJSONDeckSummary]
}

nonisolated struct MTGJSONDeckResponse: Decodable, Sendable {
    let data: MTGJSONDeck
}

/// One precon, ~150KB. Each card carries `identifiers.scryfallId`, so a deck
/// maps straight onto the cards we already store.
nonisolated struct MTGJSONDeck: Codable, Sendable {
    let code: String
    let name: String
    let type: String?
    let releaseDate: String?
    /// Where the list was taken from (a Wizards article, the wiki).
    var source: String? = nil
    let commander: [MTGJSONDeckCard]?
    let mainBoard: [MTGJSONDeckCard]
    let sideBoard: [MTGJSONDeckCard]?

    var copies: Int { ((commander ?? []) + mainBoard).reduce(0) { $0 + $1.count } }
}

nonisolated struct MTGJSONDeckCard: Codable, Sendable {
    let name: String
    let count: Int
    let uuid: String
    let number: String?
    let setCode: String?
    var isFoil: Bool? = nil
    /// WUBRG letters.
    var colorIdentity: [String]? = nil
    let identifiers: MTGJSONIdentifiers

    var scryfallID: String? { identifiers.scryfallId }
}

// MARK: - Prices (`AllPricesToday.json`)

/// Envelope for `/api/v5/AllPricesToday.json`: uuid -> per-game price data.
nonisolated struct MTGJSONPricesResponse: Decodable, Sendable {
    let data: [String: MTGJSONCardPrices]
}

nonisolated struct MTGJSONCardPrices: Decodable, Sendable {
    let paper: [String: MTGJSONProviderPrices]?
}

/// One provider (tcgplayer, cardmarket, cardkingdom) for one card.
nonisolated struct MTGJSONProviderPrices: Decodable, Sendable {
    let currency: String?
    let retail: MTGJSONFinishPrices?
    let buylist: MTGJSONFinishPrices?
}

/// Date-keyed series per finish; `AllPricesToday` carries a single date.
nonisolated struct MTGJSONFinishPrices: Decodable, Sendable {
    let normal: [String: Double]?
    let foil: [String: Double]?

    /// Most recent value for a finish, since the payload is date-keyed.
    func latest(foil wantFoil: Bool) -> Double? {
        let series = wantFoil ? foil : normal
        guard let series, let newest = series.keys.max() else { return nil }
        return series[newest]
    }
}

/// Normalised price view the app consumes, independent of provider quirks.
/// Mirrors what MTGJSON actually has: one retail and one buylist number.
nonisolated struct CardPriceQuote: Sendable, Hashable {
    let retail: Double?
    /// What a vendor pays to buy the card from you. Scryfall has no equivalent.
    let buylist: Double?
    let vendor: String
    let currency: String
}
