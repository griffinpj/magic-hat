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

nonisolated struct CardItem: Identifiable, Hashable, Sendable {
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
    let addedDate: Date?
    /// Mutable so search results can be re-marked as the collection changes.
    var owned: Bool
    /// Owning collection; empty for cards that aren't ours (search, printings).
    let collectionName: String
    /// True when `id` is a CollectionEntry id — one owned row that can be
    /// edited or removed. Printings and search hits carry a Scryfall id.
    var isEntry: Bool { owned && !collectionName.isEmpty }

    // Visuals + gameplay text (may be nil before hydration).
    let imageURL: String?
    let artCropURL: String?
    let aspectRatio: Double
    let typeLine: String?
    let manaCost: String?
    let oracleText: String?
    let power: String?
    let toughness: String?

    // Scryfall market prices (USD).
    let priceUSD: Double?
    let priceUSDFoil: Double?

    // Sort keys, computed once. Comparing these is ~50x cheaper than
    // localizedCaseInsensitiveCompare on every comparison, which is what made
    // sorting 3,900 cards a visible pause.
    let sortKey: String
    let collectorNumberValue: Int
    let rarityRankValue: Int

    /// Price paid at import, if the CSV had one (for gain/loss display).
    let purchasePrice: Double?

    // Free extras Scryfall returns in the same batch call.
    let legalities: [String: String]?
    let edhrecRank: Int?
    let purchaseURIs: [String: String]?

    var powerToughness: String? {
        guard let power, let toughness else { return nil }
        return "\(power)/\(toughness)"
    }

    /// Case- and diacritic-insensitive key for ordering by name.
    static func sortKey(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Numeric collector number; non-numeric ("216s", "★") sort last.
    static func collectorValue(_ raw: String) -> Int {
        Int(raw) ?? Int(raw.prefix { $0.isNumber }) ?? Int.max
    }

    /// Rarity ordering, low → high. Unknown rarity sorts lowest.
    static func rarityRank(_ raw: String) -> Int {
        switch raw.lowercased() {
        case "common": return 0
        case "uncommon": return 1
        case "rare": return 2
        case "mythic": return 3
        case "special": return 4
        case "bonus": return 5
        default: return -1
        }
    }

    /// Current market price for this item's finish.
    var marketPrice: Double? {
        finish == .normal ? priceUSD : (priceUSDFoil ?? priceUSD)
    }

    /// Change in value against the price paid at import.
    var gainLoss: (amount: Double, percent: Double)? {
        guard let market = marketPrice, let paid = purchasePrice, paid > 0 else { return nil }
        let diff = market - paid
        return (diff, diff / paid * 100)
    }
}

nonisolated extension CardItem {
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
        self.addedDate = entry.addedDate
        self.owned = true
        self.collectionName = entry.collectionName
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
        self.sortKey = Self.sortKey(for: self.name)
        self.collectorNumberValue = Self.collectorValue(entry.collectorNumber)
        self.rarityRankValue = Self.rarityRank(entry.rarity)
        self.purchasePrice = entry.purchasePrice
        self.legalities = meta?.legalities
        self.edhrecRank = meta?.edhrecRank
        self.purchaseURIs = meta?.purchaseURIs
    }

    /// A card built straight from a Scryfall result (e.g. a printing or a
    /// search hit). `owned` marks whether it's already in the collection.
    init(scryfallCard card: ScryfallCard, owned: Bool) {
        self.id = card.id
        self.scryfallID = card.id
        self.oracleID = card.bestOracleID
        self.name = card.name
        self.setCode = card.set
        self.setName = card.setName
        self.collectorNumber = card.collectorNumber
        self.rarity = card.rarity
        self.quantity = 1
        self.finish = .normal
        self.condition = "near_mint"
        self.language = "en"
        self.addedDate = nil
        self.owned = owned
        self.collectionName = ""
        self.imageURL = card.bestImageURIs?.normal
        self.artCropURL = card.bestImageURIs?.artCrop
        self.aspectRatio = card.isLandscape ? 680.0/488.0 : 488.0/680.0
        self.typeLine = card.bestTypeLine
        self.manaCost = card.bestManaCost
        self.oracleText = card.bestOracleText
        self.power = card.power
        self.toughness = card.toughness
        self.priceUSD = card.prices?.usd.flatMap(Double.init)
        self.priceUSDFoil = card.prices?.usdFoil.flatMap(Double.init)
        self.sortKey = Self.sortKey(for: card.name)
        self.collectorNumberValue = Self.collectorValue(card.collectorNumber)
        self.rarityRankValue = Self.rarityRank(card.rarity)
        self.purchasePrice = nil
        self.legalities = card.legalities
        self.edhrecRank = card.edhrecRank
        self.purchaseURIs = card.purchaseURIs
    }

    /// Formats to surface, in the order players care about.
    static let shownFormats = ["standard", "pioneer", "modern", "legacy", "vintage", "commander", "pauper"]

    /// Legal formats among `shownFormats`, in that order.
    var legalFormats: [String] {
        guard let legalities else { return [] }
        return Self.shownFormats.filter { legalities[$0] == "legal" }
    }
}
