//
//  ScryfallModels.swift
//  magic-hat
//
//  Decodable shapes for the subset of the Scryfall card API we consume.
//  Reference: https://scryfall.com/docs/api/cards
//

import Foundation

/// Scryfall image URLs for a single card face.
struct ScryfallImageURIs: Decodable {
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
struct ScryfallCardFace: Decodable {
    let name: String?
    let typeLine: String?
    let manaCost: String?
    let oracleText: String?
    let power: String?
    let toughness: String?
    let imageURIs: ScryfallImageURIs?

    enum CodingKeys: String, CodingKey {
        case name, power, toughness
        case typeLine = "type_line"
        case manaCost = "mana_cost"
        case oracleText = "oracle_text"
        case imageURIs = "image_uris"
    }
}

/// Scryfall market prices (USD). Low/mid tiers aren't provided by Scryfall —
/// those come from TCGplayer and are mocked in the UI.
struct ScryfallPrices: Decodable {
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
struct ScryfallCard: Decodable, Identifiable {
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
    let releasedAt: String?
    let imageURIs: ScryfallImageURIs?
    let cardFaces: [ScryfallCardFace]?
    let prices: ScryfallPrices?

    enum CodingKeys: String, CodingKey {
        case id, name, set, rarity, layout, power, toughness, prices
        case oracleID = "oracle_id"
        case setName = "set_name"
        case collectorNumber = "collector_number"
        case typeLine = "type_line"
        case manaCost = "mana_cost"
        case oracleText = "oracle_text"
        case releasedAt = "released_at"
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

    var bestTypeLine: String? { typeLine ?? cardFaces?.first?.typeLine }
    var bestManaCost: String? { manaCost ?? cardFaces?.first?.manaCost }

    /// Layouts whose images are landscape rather than the standard portrait.
    var isLandscape: Bool {
        switch layout {
        case "planar", "split", "battle": return true
        default: return false
        }
    }
}

/// Response wrapper for GET /cards/search (paginated list).
struct ScryfallListResponse: Decodable {
    let data: [ScryfallCard]
    let hasMore: Bool?
    let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
        case nextPage = "next_page"
    }
}

/// Response wrapper for POST /cards/collection.
struct ScryfallCollectionResponse: Decodable {
    let data: [ScryfallCard]
    let notFound: [ScryfallCardIdentifier]?

    enum CodingKeys: String, CodingKey {
        case data
        case notFound = "not_found"
    }
}

/// Identifier used to request cards in a collection lookup.
struct ScryfallCardIdentifier: Codable {
    let id: String?

    init(id: String) { self.id = id }
}

/// Request body for POST /cards/collection.
struct ScryfallCollectionRequest: Encodable {
    let identifiers: [ScryfallCardIdentifier]
}
