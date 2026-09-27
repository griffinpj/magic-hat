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
    /// Market prices in the display currency (see CardItem.price).
    let price: Double?
    let priceFoil: Double?

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
        price = item.price
        priceFoil = item.priceFoil
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
        price = card.prices?.price(foil: false, in: AppSettings.currency)
        priceFoil = card.prices?.price(foil: true, in: AppSettings.currency)
    }

    /// Scryfall market price for a finish (foil falls back to non-foil).
    func marketPrice(for finish: CardFinish) -> Double? {
        finish == .normal ? price : (priceFoil ?? price)
    }
}
