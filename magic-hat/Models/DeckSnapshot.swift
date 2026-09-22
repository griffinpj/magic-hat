//
//  DeckSnapshot.swift
//  magic-hat
//
//  Sendable values DeckStore builds off the main actor for the Decks tab
//  and the deck screen: what the deck lists, what of it is physically in
//  the deck, what the collection could still supply, and the stats.
//

import Foundation

/// One line of the deck as shown: the list entry plus its build state.
nonisolated struct DeckCardItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let board: DeckBoard
    let quantity: Int
    let card: CardItem
    /// Physical copies moved into the deck.
    let builtQuantity: Int
    /// Copies still in a collection (any printing), not counting other decks.
    let availableQuantity: Int

    var stillNeeded: Int { max(0, quantity - builtQuantity) }
    var missingQuantity: Int { max(0, stillNeeded - availableQuantity) }
    var value: Double { (card.priceUSD ?? 0) * Double(quantity) }

    var status: DeckCardStatus {
        if builtQuantity >= quantity { return .built }
        if builtQuantity > 0 { return .partiallyBuilt }
        if availableQuantity >= quantity { return .available }
        if availableQuantity > 0 { return .partiallyAvailable }
        return .missing
    }
}

nonisolated enum DeckCardStatus: Hashable, Sendable {
    case built, partiallyBuilt, available, partiallyAvailable, missing

    var label: String {
        switch self {
        case .built: return "In deck"
        case .partiallyBuilt: return "Partly built"
        case .available: return "In collection"
        case .partiallyAvailable: return "Some in collection"
        case .missing: return "Missing"
        }
    }

    var systemImage: String {
        switch self {
        case .built: return "checkmark.circle.fill"
        case .partiallyBuilt: return "circle.lefthalf.filled"
        case .available: return "tray.full"
        case .partiallyAvailable: return "tray"
        case .missing: return "xmark.circle"
        }
    }
}

nonisolated struct DeckSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Mana-font glyph name for the card type.
    let glyph: String?
    let items: [DeckCardItem]

    var copies: Int { items.reduce(0) { $0 + $1.quantity } }
    var value: Double { items.reduce(0) { $0 + $1.value } }
}

nonisolated struct DeckSnapshot: Hashable, Sendable {
    let id: UUID
    let name: String
    let format: DeckFormat
    let isLocked: Bool
    let notes: String
    let createdDate: Date
    let updatedDate: Date
    /// Colour identity: the commanders' when there are any, else the
    /// colours of the mainboard.
    let identity: [ManaColor]
    let commanders: [DeckCardItem]
    /// Mainboard grouped by card type, in play order.
    let sections: [DeckSection]
    let sideboard: [DeckCardItem]
    let maybeboard: [DeckCardItem]
    let stats: DeckStats

    var allItems: [DeckCardItem] { commanders + sections.flatMap(\.items) + sideboard + maybeboard }
    var playedItems: [DeckCardItem] { commanders + sections.flatMap(\.items) }
    var mainCopies: Int { playedItems.reduce(0) { $0 + $1.quantity } }
    var builtCopies: Int { playedItems.reduce(0) { $0 + $1.builtQuantity } }
    var isBuilt: Bool { builtCopies > 0 }
    var subtitle: String {
        var s = format.label
        if let target = format.cardTarget { s += " · \(mainCopies)/\(target)" } else { s += " · \(mainCopies) cards" }
        return s
    }
}

/// A row on the Decks tab.
nonisolated struct DeckSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let format: DeckFormat
    let mainCopies: Int
    let builtCopies: Int
    let identity: [ManaColor]
    let coverArtURL: String?
    let isLocked: Bool
    let totalValue: Double
    let updatedDate: Date
}

// MARK: - Building

nonisolated struct BuildTake: Hashable, Sendable {
    let entryID: UUID
    let fromCollection: String
    let printingLabel: String
    let quantity: Int
}

nonisolated struct BuildPlanEntry: Identifiable, Hashable, Sendable {
    let id: UUID              // deck card id
    let name: String
    let board: DeckBoard
    let needed: Int
    let takes: [BuildTake]
    var ready: Int { takes.reduce(0) { $0 + $1.quantity } }
    var missing: Int { max(0, needed - ready) }
}

nonisolated struct BuildPlan: Hashable, Sendable {
    let deckID: UUID
    let deckName: String
    let sourceCollections: [String]
    let includeSideboard: Bool
    let entries: [BuildPlanEntry]

    var readyCopies: Int { entries.reduce(0) { $0 + $1.ready } }
    var missingCopies: Int { entries.reduce(0) { $0 + $1.missing } }
    var readyEntries: [BuildPlanEntry] { entries.filter { $0.ready > 0 } }
    var missingEntries: [BuildPlanEntry] { entries.filter { $0.missing > 0 } }
    var alreadyBuilt: Bool { entries.isEmpty }
}

nonisolated struct BuildResult: Hashable, Sendable {
    let actionID: UUID
    let movedCopies: Int
    let missingCopies: Int
}

nonisolated struct DisassembleResult: Hashable, Sendable {
    let actionID: UUID
    let returnedCopies: Int
}

/// A parsed list line matched to the catalog.
nonisolated struct ResolvedDeckLine: Hashable, Sendable {
    let line: DeckListLine
    let scryfallID: String?
    let oracleID: String?
    let canonicalName: String?
    var isResolved: Bool { scryfallID != nil }
}

// MARK: - CardItem from a deck row

nonisolated extension CardItem {
    /// A deck list row for display. `id` is the deck row's, so the viewer
    /// and lists key on the row, not the printing (a deck may list the same
    /// printing on two boards).
    init(deckCard: DeckCard, meta: CardMeta?, quantity: Int, owned: Bool) {
        self.id = deckCard.id.uuidString
        self.scryfallID = deckCard.scryfallID
        self.oracleID = deckCard.oracleID ?? meta?.oracleID
        self.name = meta?.name.isEmpty == false ? meta!.name : deckCard.name
        self.setCode = meta?.setCode ?? ""
        self.setName = meta?.setName ?? ""
        self.collectorNumber = meta?.collectorNumber ?? ""
        self.rarity = meta?.rarity ?? ""
        self.quantity = quantity
        self.finish = .normal
        self.condition = ""
        self.language = "en"
        self.addedDate = deckCard.addedDate
        self.owned = owned
        self.collectionName = ""
        self.imageURL = meta?.imageNormalURL
        self.artCropURL = meta?.artCropURL
        self.aspectRatio = meta?.aspectRatio ?? (488.0 / 680.0)
        self.typeLine = meta?.typeLine
        self.manaCost = meta?.manaCost
        self.oracleText = meta?.oracleText
        self.power = meta?.power
        self.toughness = meta?.toughness
        self.loyalty = meta?.loyalty
        self.colors = Self.colors(fromLetters: meta?.colorsRaw)
        self.colorIdentity = Self.colors(fromLetters: meta?.colorIdentityRaw)
        self.artist = meta?.artist
        self.priceUSD = meta?.priceUSD
        self.priceUSDFoil = meta?.priceUSDFoil
        self.sortKey = Self.sortKey(for: self.name)
        self.collectorNumberValue = Self.collectorValue(self.collectorNumber)
        self.rarityRankValue = Self.rarityRank(self.rarity)
        self.purchasePrice = nil
        self.legalities = meta?.legalities
        self.edhrecRank = meta?.edhrecRank
        self.purchaseURIs = meta?.purchaseURIs
    }
}
