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
    let imageURIs: ScryfallImageURIs?

    enum CodingKeys: String, CodingKey {
        case name
        case imageURIs = "image_uris"
    }
}

/// A Scryfall card object (subset of fields).
struct ScryfallCard: Decodable {
    let id: String
    let name: String
    let set: String
    let setName: String
    let collectorNumber: String
    let rarity: String
    let layout: String?
    let imageURIs: ScryfallImageURIs?
    let cardFaces: [ScryfallCardFace]?

    enum CodingKeys: String, CodingKey {
        case id, name, set, rarity, layout
        case setName = "set_name"
        case collectorNumber = "collector_number"
        case imageURIs = "image_uris"
        case cardFaces = "card_faces"
    }

    /// Best available image URIs: top-level, else the first face's.
    var bestImageURIs: ScryfallImageURIs? {
        imageURIs ?? cardFaces?.first?.imageURIs
    }

    /// Layouts whose images are landscape rather than the standard portrait.
    var isLandscape: Bool {
        switch layout {
        case "planar", "split", "battle": return true
        default: return false
        }
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
