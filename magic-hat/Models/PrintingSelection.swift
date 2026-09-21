//
//  PrintingSelection.swift
//  magic-hat
//
//  The printing a user is adding: enough of a card to create the entry and a
//  placeholder CardMeta if we've never seen it. Built from a CardItem (the
//  card the overlay was showing) or from a ScryfallCard (a printing picked
//  in the set picker).
//

import Foundation

nonisolated struct PrintingSelection: Hashable, Sendable, Identifiable {
    let scryfallID: String
    let oracleID: String?
    let name: String
    let setCode: String
    let setName: String
    let collectorNumber: String
    let rarity: String
    let imageURL: String?
    let artCropURL: String?
    let aspectRatio: Double
    let priceUSD: Double?
    let priceUSDFoil: Double?

    var id: String { scryfallID }

    init(item: CardItem) {
        scryfallID = item.scryfallID
        oracleID = item.oracleID
        name = item.name
        setCode = item.setCode
        setName = item.setName
        collectorNumber = item.collectorNumber
        rarity = item.rarity
        imageURL = item.imageURL
        artCropURL = item.artCropURL
        aspectRatio = item.aspectRatio
        priceUSD = item.priceUSD
        priceUSDFoil = item.priceUSDFoil
    }

    init(card: ScryfallCard) {
        scryfallID = card.id
        oracleID = card.bestOracleID
        name = card.name
        setCode = card.set
        setName = card.setName
        collectorNumber = card.collectorNumber
        rarity = card.rarity
        imageURL = card.bestImageURIs?.normal
        artCropURL = card.bestImageURIs?.artCrop
        aspectRatio = card.isLandscape ? 680.0 / 488.0 : 488.0 / 680.0
        priceUSD = card.prices?.usd.flatMap(Double.init)
        priceUSDFoil = card.prices?.usdFoil.flatMap(Double.init)
    }

    /// Scryfall market price for a finish (foil falls back to non-foil).
    func marketPrice(for finish: CardFinish) -> Double? {
        finish == .normal ? priceUSD : (priceUSDFoil ?? priceUSD)
    }
}
