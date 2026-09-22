//
//  ScryfallModels.swift
//  magic-hat
//
//  Decodable shapes for the subset of the Scryfall card API we consume.
//  Reference: https://scryfall.com/docs/api/cards
//

import Foundation

/// Scryfall image URLs for a single card face.
nonisolated struct ScryfallImageURIs: Codable, Sendable {
    let small: String?
    let normal: String?
    let large: String?
    let png: String?
    let artCrop: String?
    let borderCrop: String?

    enum CodingKeys: String, CodingKey {
        case small, normal, large, png
        case artCrop = "art_crop"
        case borderCrop = "border_crop"
    }
}

/// One face of a (possibly multi-faced) card.
nonisolated struct ScryfallCardFace: Codable, Sendable {
    let name: String?
    /// Reversible cards carry oracle_id per face, not at the top level.
    let oracleID: String?
    let typeLine: String?
    let manaCost: String?
    let oracleText: String?
    let power: String?
    let toughness: String?
    let colors: [String]?
    let imageURIs: ScryfallImageURIs?

    enum CodingKeys: String, CodingKey {
        case name, power, toughness, colors
        case oracleID = "oracle_id"
        case typeLine = "type_line"
        case manaCost = "mana_cost"
        case oracleText = "oracle_text"
        case imageURIs = "image_uris"
    }
}

/// Scryfall market prices (USD). Low/mid tiers aren't provided by Scryfall —
/// those come from TCGplayer and are mocked in the UI.
nonisolated struct ScryfallPrices: Codable, Sendable {
    let usd: String?
    let usdFoil: String?
    let usdEtched: String?

    enum CodingKeys: String, CodingKey {
        case usd
        case usdFoil = "usd_foil"
        case usdEtched = "usd_etched"
    }
}

/// A Scryfall card object (subset of fields).
nonisolated struct ScryfallCard: Codable, Identifiable, Sendable {
    let id: String
    let oracleID: String?
    let name: String
    let set: String
    let setName: String
    let collectorNumber: String
    let rarity: String
    let layout: String?
    let typeLine: String?
    let manaCost: String?
    let oracleText: String?
    let power: String?
    let toughness: String?
    let loyalty: String?
    /// Printed colours; multi-faced layouts carry them per face instead.
    let colors: [String]?
    let colorIdentity: [String]?
    let artist: String?
    let releasedAt: String?
    let legalities: [String: String]?
    let edhrecRank: Int?
    let tcgplayerID: Int?
    let purchaseURIs: [String: String]?
    let imageURIs: ScryfallImageURIs?
    let cardFaces: [ScryfallCardFace]?
    let prices: ScryfallPrices?

    enum CodingKeys: String, CodingKey {
        case id, name, set, rarity, layout, power, toughness, prices, legalities, loyalty, colors, artist
        case colorIdentity = "color_identity"
        case oracleID = "oracle_id"
        case setName = "set_name"
        case collectorNumber = "collector_number"
        case typeLine = "type_line"
        case manaCost = "mana_cost"
        case oracleText = "oracle_text"
        case releasedAt = "released_at"
        case edhrecRank = "edhrec_rank"
        case tcgplayerID = "tcgplayer_id"
        case purchaseURIs = "purchase_uris"
        case imageURIs = "image_uris"
        case cardFaces = "card_faces"
    }

    /// Best available image URIs: top-level, else the first face's.
    var bestImageURIs: ScryfallImageURIs? {
        imageURIs ?? cardFaces?.first?.imageURIs
    }

    /// Oracle text, falling back to joined face texts for multi-faced cards.
    var bestOracleText: String? {
        if let oracleText, !oracleText.isEmpty { return oracleText }
        let faces = cardFaces?.compactMap { face -> String? in
            guard let t = face.oracleText, !t.isEmpty else { return nil }
            return "\(face.name ?? "")\n\(t)"
        }
        guard let faces, !faces.isEmpty else { return nil }
        return faces.joined(separator: "\n\n//\n\n")
    }

    /// Top-level oracle id, else the first face's (reversible layouts).
    var bestOracleID: String? { oracleID ?? cardFaces?.first?.oracleID }

    var bestTypeLine: String? { typeLine ?? cardFaces?.first?.typeLine }
    var bestManaCost: String? { manaCost ?? cardFaces?.first?.manaCost }
    /// Top-level colours, else the front face's (transform, modal DFC).
    var bestColors: [String]? { colors ?? cardFaces?.first?.colors }

    /// Layouts whose images are landscape rather than the standard portrait.
    var isLandscape: Bool {
        switch layout {
        case "planar", "split", "battle": return true
        default: return false
        }
    }
}

/// A Scryfall set object (subset). `iconSVGURI` is an SVG (no raster form).
nonisolated struct ScryfallSet: Codable, Sendable, Identifiable, Hashable {
    let code: String
    let name: String?
    let iconSVGURI: String?
    let setType: String?
    /// "YYYY-MM-DD".
    let releasedAt: String?
    let cardCount: Int?
    let digital: Bool?
    let parentSetCode: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, name, digital
        case iconSVGURI = "icon_svg_uri"
        case setType = "set_type"
        case releasedAt = "released_at"
        case cardCount = "card_count"
        case parentSetCode = "parent_set_code"
    }

    init(code: String, name: String?, iconSVGURI: String? = nil, setType: String? = nil,
         releasedAt: String? = nil, cardCount: Int? = nil, digital: Bool? = nil, parentSetCode: String? = nil) {
        self.code = code; self.name = name; self.iconSVGURI = iconSVGURI; self.setType = setType
        self.releasedAt = releasedAt; self.cardCount = cardCount; self.digital = digital
        self.parentSetCode = parentSetCode
    }

    var releaseYear: Int? { releasedAt.flatMap { Int($0.prefix(4)) } }
}

/// Response wrapper for GET /sets.
nonisolated struct ScryfallSetListResponse: Decodable, Sendable {
    let data: [ScryfallSet]
}

/// GET /catalog/:name and GET /cards/autocomplete both answer `{ data: [String] }`.
nonisolated struct ScryfallStringListResponse: Decodable, Sendable {
    let data: [String]
}

/// Response wrapper for GET /cards/search (paginated list).
nonisolated struct ScryfallListResponse: Decodable, Sendable {
    let data: [ScryfallCard]
    let hasMore: Bool?
    let nextPage: String?
    let totalCards: Int?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
        case totalCards = "total_cards"
    }
}

/// One page of search results, as the app consumes it.
nonisolated struct ScryfallSearchPage: Sendable {
    let cards: [ScryfallCard]
    let totalCards: Int?
    let nextPage: URL?

    static let empty = ScryfallSearchPage(cards: [], totalCards: 0, nextPage: nil)
}

/// Response wrapper for POST /cards/collection.
nonisolated struct ScryfallCollectionResponse: Decodable, Sendable {
    let data: [ScryfallCard]
    let notFound: [ScryfallCardIdentifier]?

    enum CodingKeys: String, CodingKey {
        case data
        case notFound = "not_found"
    }
}

/// Identifier used to request cards in a collection lookup.
nonisolated struct ScryfallCardIdentifier: Codable, Sendable {
    let id: String?

    init(id: String) { self.id = id }
}

/// Request body for POST /cards/collection.
nonisolated struct ScryfallCollectionRequest: Encodable, Sendable {
    let identifiers: [ScryfallCardIdentifier]
}
