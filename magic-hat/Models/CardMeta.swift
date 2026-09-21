//
//  CardMeta.swift
//  magic-hat
//
//  Cached Scryfall card metadata, keyed by Scryfall ID. Shared by all
//  CollectionEntry rows that reference the same card so we hydrate once.
//

import Foundation
import SwiftData

/// Hydration state for a card's Scryfall metadata.
enum CardFetchState: Int, Codable {
    case pending    // never fetched
    case fetched    // metadata + image URLs available
    case failed     // last fetch failed; safe to retry
}

@Model
final class CardMeta {
    /// Scryfall UUID (e.g. "69b215fe-0d97-4ca1-9490-174220fd454b").
    @Attribute(.unique) var scryfallID: String

    var name: String
    var setCode: String
    var setName: String
    var collectorNumber: String
    var rarity: String

    /// Image URLs by Scryfall size key. We primarily use `normal`.
    var imageSmallURL: String?
    var imageNormalURL: String?
    var imageLargeURL: String?
    var artCropURL: String?

    /// Gameplay text (cached so the overlay/detail hero renders from cache).
    var oracleID: String?
    var typeLine: String?
    var manaCost: String?
    var oracleText: String?
    var power: String?
    var toughness: String?

    /// Scryfall market prices (USD). Low/mid tiers are not provided by
    /// Scryfall (TCGplayer only) and are mocked in the UI.
    var priceUSD: Double?
    var priceUSDFoil: Double?
    /// When prices were last refreshed, so they can go stale independently of
    /// the (immutable) card metadata.
    var pricesUpdatedAt: Date?

    /// Pixel dimensions of the `normal` image so tiles match the true
    /// aspect ratio (most cards are 488x680; battle/planar are landscape).
    var imageWidth: Int
    var imageHeight: Int

    var fetchStateRaw: Int
    var lastFetched: Date?

    var fetchState: CardFetchState {
        get { CardFetchState(rawValue: fetchStateRaw) ?? .pending }
        set { fetchStateRaw = newValue.rawValue }
    }

    /// Aspect ratio (width / height) for laying out tiles.
    var aspectRatio: Double {
        guard imageHeight > 0 else { return 488.0 / 680.0 }
        return Double(imageWidth) / Double(imageHeight)
    }

    init(
        scryfallID: String,
        name: String = "",
        setCode: String = "",
        setName: String = "",
        collectorNumber: String = "",
        rarity: String = "",
        imageWidth: Int = 488,
        imageHeight: Int = 680,
        fetchState: CardFetchState = .pending
    ) {
        self.scryfallID = scryfallID
        self.name = name
        self.setCode = setCode
        self.setName = setName
        self.collectorNumber = collectorNumber
        self.rarity = rarity
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.fetchStateRaw = fetchState.rawValue
    }
}
