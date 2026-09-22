//
//  DeckEditController.swift
//  magic-hat
//
//  Small, user-initiated edits to a deck's *list* on the main context:
//  create, rename, lock, notes, commander, add/remove/count a card, import
//  resolved lines. These touch no physical cards, so they write no
//  AuditRecords — the ledger tracks copies owned, and a list is a wish.
//  Building and disassembling (which do move copies) live in DeckBuilder.
//

import Foundation
import SwiftData

@MainActor
enum DeckEditController {
    enum EditError: Error, LocalizedError {
        case emptyName
        var errorDescription: String? { "Give the deck a name." }
    }

    @discardableResult
    static func createDeck(name: String, format: DeckFormat, commander: PrintingSelection?, context: ModelContext) throws -> Deck {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EditError.emptyName }
        let deck = Deck(name: trimmed, format: format)
        context.insert(deck)
        if let commander, format.hasCommander {
            let card = DeckCard(scryfallID: commander.scryfallID, oracleID: commander.oracleID,
                                name: commander.name, board: .commander, quantity: 1)
            card.deck = deck
            context.insert(card)
            deck.coverArtURL = commander.artCropURL
        }
        try context.save()
        DeckChangeTracker.shared.bump()
        return deck
    }

    /// Deletes the list. The caller disassembles first if the deck is
    /// built — the physical cards must go home before their deck vanishes.
    static func delete(deckID: UUID, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        context.delete(deck)
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    static func rename(deckID: UUID, to name: String, context: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let deck = try fetch(deckID, context: context) else { return }
        deck.name = trimmed
        try touch(deck, context: context)
    }

    static func setLocked(deckID: UUID, _ locked: Bool, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        deck.isLocked = locked
        try touch(deck, context: context)
    }

    static func setNotes(deckID: UUID, _ notes: String, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        deck.notes = notes
        try touch(deck, context: context)
    }

    static func setFormat(deckID: UUID, _ format: DeckFormat, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        deck.format = format
        try touch(deck, context: context)
    }

    /// Replaces the commander (nil clears it). A partner pair is two calls
    /// with `replace: false`.
    static func setCommander(deckID: UUID, _ printing: PrintingSelection?, replace: Bool = true, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        if replace {
            for card in deck.cards where card.board == .commander { context.delete(card) }
        }
        if let printing {
            let card = DeckCard(scryfallID: printing.scryfallID, oracleID: printing.oracleID,
                                name: printing.name, board: .commander, quantity: 1)
            card.deck = deck
            context.insert(card)
            deck.coverArtURL = printing.artCropURL
        } else if replace {
            deck.coverArtURL = nil
        }
        try touch(deck, context: context)
    }

    /// Adds copies to a board, merging with the same card (by oracle id)
    /// already on that board.
    @discardableResult
    static func add(_ printing: PrintingSelection, to deckID: UUID, board: DeckBoard, quantity: Int = 1, context: ModelContext) throws -> UUID? {
        guard quantity > 0, let deck = try fetch(deckID, context: context) else { return nil }
        let matchKey = printing.oracleID ?? printing.scryfallID
        if let existing = deck.cards.first(where: { $0.board == board && $0.matchKey == matchKey }) {
            existing.quantity += quantity
            try touch(deck, context: context)
            return existing.id
        }
        let card = DeckCard(scryfallID: printing.scryfallID, oracleID: printing.oracleID,
                            name: printing.name, board: board, quantity: quantity)
        card.deck = deck
        context.insert(card)
        if deck.coverArtURL == nil { deck.coverArtURL = printing.artCropURL }
        try touch(deck, context: context)
        return card.id
    }

    /// Sets a row's quantity; zero removes the row.
    static func setQuantity(deckCardID: UUID, _ quantity: Int, context: ModelContext) throws {
        guard let card = try fetchCard(deckCardID, context: context), let deck = card.deck else { return }
        if quantity <= 0 {
            context.delete(card)
        } else {
            card.quantity = quantity
        }
        try touch(deck, context: context)
    }

    static func move(deckCardID: UUID, to board: DeckBoard, context: ModelContext) throws {
        guard let card = try fetchCard(deckCardID, context: context), let deck = card.deck else { return }
        if let other = deck.cards.first(where: { $0.id != card.id && $0.board == board && $0.matchKey == card.matchKey }) {
            other.quantity += card.quantity
            context.delete(card)
        } else {
            card.board = board
        }
        try touch(deck, context: context)
    }

    /// Adds every resolved line; unresolved lines are skipped (the import
    /// sheet lists them). Returns how many copies were added.
    @discardableResult
    static func importLines(_ lines: [ResolvedDeckLine], into deckID: UUID, context: ModelContext) throws -> Int {
        guard let deck = try fetch(deckID, context: context) else { return 0 }
        var added = 0
        for resolved in lines {
            guard let scryfallID = resolved.scryfallID else { continue }
            let line = resolved.line
            let matchKey = resolved.oracleID ?? scryfallID
            if let existing = deck.cards.first(where: { $0.board == line.board && $0.matchKey == matchKey }) {
                existing.quantity += line.quantity
            } else {
                let card = DeckCard(scryfallID: scryfallID, oracleID: resolved.oracleID,
                                    name: resolved.canonicalName ?? line.name, board: line.board, quantity: line.quantity)
                card.deck = deck
                context.insert(card)
            }
            added += line.quantity
        }
        try touch(deck, context: context)
        return added
    }

    // MARK: Helpers

    private static func touch(_ deck: Deck, context: ModelContext) throws {
        deck.updatedDate = Date()
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    private static func fetch(_ id: UUID, context: ModelContext) throws -> Deck? {
        try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == id })).first
    }

    private static func fetchCard(_ id: UUID, context: ModelContext) throws -> DeckCard? {
        try context.fetch(FetchDescriptor<DeckCard>(predicate: #Predicate { $0.id == id })).first
    }
}
