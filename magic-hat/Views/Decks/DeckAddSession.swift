//
//  DeckAddSession.swift
//  magic-hat
//
//  What the add sheet and the viewer it presents both need to know: which
//  deck and board cards go to, and how many of each card are already there.
//  One observable object, so the viewer's −/+ and the row's −/+ read and
//  write the same numbers, and a deck write refreshes both at once when
//  the sheet reloads its snapshot.
//

import Foundation
import SwiftData
import Observation

@MainActor @Observable
final class DeckAddSession {
    struct Row: Hashable {
        let id: UUID
        let quantity: Int
    }

    let deckID: UUID
    private(set) var deckName = ""
    var board: DeckBoard {
        didSet { recompute() }
    }
    /// Rows on `board`, by card key (oracle id, else Scryfall id).
    private(set) var rows: [String: Row] = [:]
    /// The commander's colour identity, for narrowing a search; nil when
    /// the deck has no commander to narrow by.
    private(set) var identityFilter: [ManaColor]?
    /// Cards this session has written (by card key), from a row's + or the
    /// viewer's stepper alike. A list that hides what the deck already
    /// holds keeps these in place as steppers whatever the deck says: the
    /// deck screen re-plans on the same write, and its plan can land
    /// before the sheet has re-read the deck, so the counts alone are not
    /// proof the card was put in here. Never cleared: a card stepped back
    /// to zero stays where it was, with Add, rather than jumping away.
    private(set) var touched: Set<String> = []
    private var snapshot: DeckSnapshot?
    private let context: ModelContext

    init(deckID: UUID, board: DeckBoard = .main, context: ModelContext) {
        self.deckID = deckID
        self.board = board
        self.context = context
    }

    func update(from snapshot: DeckSnapshot) {
        self.snapshot = snapshot
        deckName = snapshot.name
        identityFilter = snapshot.format.hasCommander && !snapshot.commanders.isEmpty ? snapshot.identity : nil
        recompute()
    }

    private func recompute() {
        var out: [String: Row] = [:]
        for item in snapshot?.allItems ?? [] where item.board == board {
            let key = item.card.oracleID ?? item.card.scryfallID
            let existing = out[key]?.quantity ?? 0
            out[key] = Row(id: item.id, quantity: existing + item.quantity)
        }
        rows = out
    }

    nonisolated static func key(of item: CardItem) -> String { item.oracleID ?? item.scryfallID }

    func quantity(of item: CardItem) -> Int { rows[Self.key(of: item)]?.quantity ?? 0 }

    // Writes update `rows` as well as the store, so a row's stepper and
    // the viewer's count move on the tap. Otherwise they waited for the
    // deck to be re-read off the main actor — a round trip that queues
    // behind the deck screen's and the Decks tab's own re-reads of the same
    // write. The next snapshot (`update(from:)`) replaces these counts.

    /// Adds one copy to `board` (or another board), merging with the same
    /// card already there.
    func add(_ item: CardItem, to board: DeckBoard? = nil) throws {
        let target = board ?? self.board
        let id = try DeckEditController.add(PrintingSelection(item: item), to: deckID, board: target, context: context)
        let key = Self.key(of: item)
        touched.insert(key)
        if target == self.board, let id { rows[key] = Row(id: id, quantity: (rows[key]?.quantity ?? 0) + 1) }
    }

    /// Sets the copies of `item` on `board`; zero removes the row.
    func setQuantity(_ item: CardItem, _ quantity: Int) throws {
        let key = Self.key(of: item)
        if let row = rows[key] {
            try DeckEditController.setQuantity(deckCardID: row.id, max(0, quantity), context: context)
            rows[key] = quantity > 0 ? Row(id: row.id, quantity: quantity) : nil
        } else if quantity > 0,
                  let id = try DeckEditController.add(PrintingSelection(item: item), to: deckID, board: board,
                                                      quantity: quantity, context: context) {
            rows[key] = Row(id: id, quantity: quantity)
        }
        touched.insert(key)
    }
}
