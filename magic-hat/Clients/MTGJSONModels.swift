//
//  MTGJSONModels.swift
//  magic-hat
//
//  Decodable shapes for the MTGJSON v5 bulk API (https://mtgjson.com/api/v5/).
//
//  MTGJSON is our second metadata provider. It matters because Scryfall
//  exposes a single market price per finish, while MTGJSON aggregates the
//  full retail picture — low / mid / market (and buylist) across TCGplayer,
//  Cardmarket and Card Kingdom — which is what the LOW/MID columns want.
//
//  Two things to know about the shape of this API:
//   * It is bulk-only. There is no "one card" endpoint; you fetch a set file
//     or a prices file.
//   * Prices are keyed by MTGJSON UUID, not Scryfall ID. Set files carry
//     `identifiers.scryfallId`, which is how the two are bridged.
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

nonisolated struct MTGJSONIdentifiers: Decodable, Sendable {
    let scryfallId: String?
    let tcgplayerProductId: String?
    let cardKingdomId: String?
    let mcmId: String?
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
nonisolated struct CardPriceQuote: Sendable, Hashable {
    let low: Double?
    let mid: Double?
    let market: Double?
    let currency: String
}
