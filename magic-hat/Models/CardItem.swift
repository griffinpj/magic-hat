//
//  CardItem.swift
//  magic-hat
//
//  A presentation-layer value type describing one card for the reusable card
//  grid / overlay / detail UI. Decoupled from SwiftData and Scryfall models so
//  the same views can be driven by the collection (owned cards) or, later, by
//  Search (Scryfall results). Build one via the CollectionEntry+CardMeta or
//  ScryfallCard convenience initializers.
//

import Foundation

struct CardItem: Identifiable, Hashable, Sendable {
    /// Stable identity for the grid (entry id for owned cards, else scryfallID).
    let id: String
    let scryfallID: String
    let oracleID: String?

    let name: String
    let setCode: String
    let setName: String
    let collectorNumber: String
    let rarity: String

    // Ownership / printing specifics (zero/empty for non-owned search results).
    let quantity: Int
    let finish: CardFinish
    let condition: String
    let language: String
    let binderName: String
    let addedDate: Date?
    let owned: Bool

    // Visuals + gameplay text (may be nil before hydration).
    let imageURL: String?
    let artCropURL: String?
    let aspectRatio: Double
    let typeLine: String?
    let manaCost: String?
    let oracleText: String?
    let power: String?
    let toughness: String?

    // Scryfall market prices (USD); low/mid are TCGplayer-only and mocked.
    let priceUSD: Double?
    let priceUSDFoil: Double?

    var powerToughness: String? {
        guard let power, let toughness else { return nil }
        return "\(power)/\(toughness)"
    }
}

extension CardItem {
    /// Owned card built from a collection entry plus its (optional) cached meta.
    init(entry: CollectionEntry, meta: CardMeta?) {
        self.id = entry.id.uuidString
        self.scryfallID = entry.scryfallID
        self.oracleID = meta?.oracleID
        self.name = meta?.name.isEmpty == false ? meta!.name : entry.name
        self.setCode = entry.setCode
        self.setName = entry.setName
        self.collectorNumber = entry.collectorNumber
        self.rarity = entry.rarity
        self.quantity = entry.quantity
        self.finish = entry.finish
        self.condition = entry.condition
        self.language = entry.language
        self.binderName = entry.binderName
        self.addedDate = entry.addedDate
        self.owned = true
        self.imageURL = meta?.imageNormalURL
        self.artCropURL = meta?.artCropURL
        self.aspectRatio = meta?.aspectRatio ?? (488.0 / 680.0)
        self.typeLine = meta?.typeLine
        self.manaCost = meta?.manaCost
        self.oracleText = meta?.oracleText
        self.power = meta?.power
        self.toughness = meta?.toughness
        self.priceUSD = meta?.priceUSD
        self.priceUSDFoil = meta?.priceUSDFoil
    }
}
