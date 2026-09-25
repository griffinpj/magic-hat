//
//  Deck.swift
//  magic-hat
//
//  A deck is a *list* (DeckCard rows: what the deck wants, per board) plus,
//  once built, a hidden collection of the physical cards moved into it
//  (CollectionEntry rows whose collectionName is `collectionKey`). The two
//  layers are joined by oracle id, so a deck that lists one printing is
//  satisfied by any printing the collection holds. Building moves rows out
//  of a collection into the deck's key and records where each came from;
//  disassembling moves them back. Copies are never duplicated.
//

import Foundation
import SwiftData

nonisolated enum DeckFormat: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case commander, brawl, oathbreaker, standard, pioneer, modern, legacy, vintage, pauper, other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .other: return "Casual"
        default: return rawValue.capitalized
        }
    }

    /// Scryfall legalities key; nil means no legality check.
    var legalityKey: String? { self == .other ? nil : rawValue }

    var hasCommander: Bool { self == .commander || self == .brawl || self == .oathbreaker }
    var isSingleton: Bool { hasCommander }
    /// Maximum copies of one card outside basic lands.
    var maxCopies: Int { isSingleton ? 1 : 4 }
    /// Mainboard size including the commander, nil when the format doesn't fix it.
    var cardTarget: Int? {
        switch self {
        case .commander: return 100
        case .brawl, .oathbreaker: return 60
        case .standard, .pioneer, .modern, .legacy, .vintage, .pauper: return 60
        case .other: return nil
        }
    }
    var sideboardTarget: Int? { hasCommander || self == .other ? nil : 15 }
}

nonisolated enum DeckBoard: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case commander, main, side, maybe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commander: return "Commander"
        case .main: return "Mainboard"
        case .side: return "Sideboard"
        case .maybe: return "Maybeboard"
        }
    }

    /// Boards a card can be added to from search (the commander is chosen
    /// on the deck itself).
    static let addable: [DeckBoard] = [.main, .side, .maybe]

    /// Boards that count as the deck when building or judging legality.
    var isPlayed: Bool { self == .commander || self == .main }
}

@Model
nonisolated final class Deck {
    @Attribute(.unique) var id: UUID
    var name: String
    var formatRaw: String
    /// Locked: the list is read-only and the search field filters the deck
    /// instead of adding to it.
    var isLocked: Bool
    var notes: String
    var createdDate: Date
    var updatedDate: Date
    /// Art crop for the Decks tab tile: the commander's, else the first card's.
    var coverArtURL: String?

    @Relationship(deleteRule: .cascade, inverse: \DeckCard.deck)
    var cards: [DeckCard]

    init(id: UUID = UUID(), name: String, format: DeckFormat, notes: String = "", createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.formatRaw = format.rawValue
        self.isLocked = false
        self.notes = notes
        self.createdDate = createdDate
        self.updatedDate = createdDate
        self.cards = []
    }

    var format: DeckFormat {
        get { DeckFormat(rawValue: formatRaw) ?? .other }
        set { formatRaw = newValue.rawValue }
    }

    /// The hidden collection holding the deck's built cards.
    var collectionKey: String { Self.collectionKey(for: id) }

    static func collectionKey(for id: UUID) -> String { "\(collectionKeyPrefix)\(id.uuidString)" }
    static let collectionKeyPrefix = "deck:"
    static func isDeckCollection(_ name: String) -> Bool { name.hasPrefix(collectionKeyPrefix) }
    static func deckID(fromCollectionKey key: String) -> UUID? {
        guard key.hasPrefix(collectionKeyPrefix) else { return nil }
        return UUID(uuidString: String(key.dropFirst(collectionKeyPrefix.count)))
    }
}

@Model
nonisolated final class DeckCard {
    @Attribute(.unique) var id: UUID
    var deck: Deck?
    /// The printing the list named (or the one chosen when added). Display
    /// only — building matches by oracle id.
    var scryfallID: String
    var oracleID: String?
    var name: String
    var boardRaw: String
    var quantity: Int
    var addedDate: Date

    init(id: UUID = UUID(), scryfallID: String, oracleID: String?, name: String,
         board: DeckBoard, quantity: Int, addedDate: Date = Date()) {
        self.id = id
        self.scryfallID = scryfallID
        self.oracleID = oracleID
        self.name = name
        self.boardRaw = board.rawValue
        self.quantity = quantity
        self.addedDate = addedDate
    }

    var board: DeckBoard {
        get { DeckBoard(rawValue: boardRaw) ?? .main }
        set { boardRaw = newValue.rawValue }
    }

    /// What building and availability match on: the card, not the printing.
    var matchKey: String { oracleID ?? scryfallID }
}

/// What a deck's search offers: everything, or the cards recommended for
/// this deck. "In collection" is a chip on either, not a scope: it
/// narrows what is shown to what is owned.
nonisolated enum DeckSearchScope: String, CaseIterable, Hashable, Sendable {
    case all, recommended
    var label: String {
        switch self {
        case .all: return "All Cards"
        case .recommended: return "Recommended"
        }
    }
}
