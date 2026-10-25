//
//  DeckEditController.swift
//  magic-hat
//
//  Small, user-initiated edits to a deck's *list* on the main context:
//  create, rename, lock, notes, commander, add/remove/count a card, import
//  resolved lines. These touch no physical cards, so list edits write no
//  AuditRecords — the ledger tracks copies owned, and a list is a wish.
//  Creating and deleting a deck are the exceptions: each is a History
//  action (no copies moved) carrying the deck, so either can be undone.
//  Building and disassembling (which do move copies) live in DeckBuilder.
//

import Foundation
import SwiftData

@MainActor
enum DeckEditController {
    enum EditError: Error, LocalizedError {
        case emptyName
        case stillBuilt
        var errorDescription: String? {
            switch self {
            case .emptyName: return "Give the deck a name."
            case .stillBuilt: return "The deck still holds cards. Disassemble it first."
            }
        }
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
        // A History action, as deleting is: Undo takes the deck away again.
        let record = AuditRecord(actionID: UUID(), action: .deckCreate, scryfallID: "", cardName: deck.name,
                                 collectionName: deck.collectionKey, finish: .normal, condition: "", quantityDelta: 0,
                                 collectionEntryID: nil)
        record.payload = try DeletedDeck(deck, in: context).encoded()
        context.insert(record)
        try context.save()
        DeckChangeTracker.shared.bump()
        // History lists it.
        CollectionChangeTracker.shared.bump()
        return deck
    }

    // MARK: Folders

    /// A new folder in `parent` (nil: the top level). Names needn't be
    /// unique, as in Files within different folders; blank is refused.
    @discardableResult
    static func createFolder(named raw: String, in parent: UUID?, context: ModelContext) throws -> DeckFolder {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        let folder = DeckFolder(name: name, parentID: parent)
        context.insert(folder)
        try context.save()
        DeckChangeTracker.shared.bump()
        return folder
    }

    static func renameFolder(_ id: UUID, to raw: String, context: ModelContext) throws {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FolderError.emptyName }
        guard let folder = try fetchFolder(id, context: context) else { return }
        folder.name = name
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    /// Deletes the folder only: its decks and folders move up into its
    /// parent, as nothing a folder holds is ever lost with it.
    static func deleteFolder(_ id: UUID, context: ModelContext) throws {
        guard let folder = try fetchFolder(id, context: context) else { return }
        let parent = folder.parentID
        let optionalID: UUID? = id
        for deck in try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.folderID == optionalID })) {
            deck.folderID = parent
        }
        for child in try context.fetch(FetchDescriptor<DeckFolder>(predicate: #Predicate { $0.parentID == optionalID })) {
            child.parentID = parent
        }
        context.delete(folder)
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    /// Files decks into `folder` (nil: the top level).
    static func moveDecks(_ ids: [UUID], to folder: UUID?, context: ModelContext) throws {
        for deck in try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { ids.contains($0.id) })) {
            deck.folderID = folder
        }
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    /// Moves a folder into another (nil: the top level). Refused into
    /// itself or anything inside it.
    static func moveFolder(_ id: UUID, to parent: UUID?, context: ModelContext) throws {
        let tree = DeckFolderTree(try context.fetch(FetchDescriptor<DeckFolder>()))
        guard !tree.isInside(parent, id) else { throw FolderError.intoItself }
        guard let folder = try fetchFolder(id, context: context) else { return }
        folder.parentID = parent
        try context.save()
        DeckChangeTracker.shared.bump()
    }

    enum FolderError: Error, LocalizedError {
        case emptyName, intoItself
        var errorDescription: String? {
            switch self {
            case .emptyName: return "Give the folder a name."
            case .intoItself: return "A folder can't go inside itself."
            }
        }
    }

    private static func fetchFolder(_ id: UUID, context: ModelContext) throws -> DeckFolder? {
        try context.fetch(FetchDescriptor<DeckFolder>(predicate: #Predicate { $0.id == id })).first
    }

    /// Deletes the deck: its list, versions and branches. The caller
    /// disassembles first if the deck is built — the physical cards must
    /// go home before their deck vanishes. It is a History action
    /// (`.deckDelete`, no copies moved) carrying the whole deck, so Undo
    /// brings it back, and with it the builds History holds against it.
    static func delete(deckID: UUID, context: ModelContext) throws {
        guard let deck = try fetch(deckID, context: context) else { return }
        // A built deck is taken apart first (DeckBuilder.disassemble, from
        // every screen that deletes). Refused rather than orphaning rows
        // under a key no deck answers to: a screen that read a stale
        // "built: 0" used to delete the deck and leave its cards showing
        // as "deck:<uuid>" wherever a row's collection is named.
        let key = deck.collectionKey
        var built = FetchDescriptor<CollectionEntry>(predicate: #Predicate { $0.collectionName == key })
        built.fetchLimit = 1
        guard try context.fetchCount(built) == 0 else { throw EditError.stillBuilt }
        let record = AuditRecord(actionID: UUID(), action: .deckDelete, scryfallID: "", cardName: deck.name,
                                 collectionName: deck.collectionKey, finish: .normal, condition: "", quantityDelta: 0,
                                 collectionEntryID: nil)
        record.payload = try DeletedDeck(deck, in: context).encoded()
        context.insert(record)
        try remove(deck, in: context)
        try context.save()
        DeckChangeTracker.shared.bump()
        // History lists it.
        CollectionChangeTracker.shared.bump()
    }

    /// The deck and what hangs off it, off `context` (no save).
    nonisolated static func remove(_ deck: Deck, in context: ModelContext) throws {
        let id = deck.id
        for version in try context.fetch(FetchDescriptor<DeckVersion>(predicate: #Predicate { $0.deckID == id })) { context.delete(version) }
        for branch in try context.fetch(FetchDescriptor<DeckBranch>(predicate: #Predicate { $0.deckID == id })) { context.delete(branch) }
        context.delete(deck)
    }

    static func rename(deckID: UUID, to name: String, context: ModelContext) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let deck = try fetch(deckID, context: context) else { return }
        deck.name = trimmed
        try touch(deck, context: context)
        // The name is on every owned row built from the deck ("Deck: Name")
        // and on History's rows; both read on this tracker.
        CollectionChangeTracker.shared.bump()
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

    /// Set as Commander on a row of the list: one copy of it becomes the
    /// commander and the commander it replaces goes to the mainboard
    /// (merging with a copy already there) — a swap, as in a deck builder.
    /// It used to delete the old commander, so promoting a partner by
    /// mistake lost the card from the list. One save.
    static func makeCommander(deckCardID: UUID, artCropURL: String? = nil, context: ModelContext) throws {
        guard let card = try fetchCard(deckCardID, context: context), let deck = card.deck, card.board != .commander else { return }
        for old in deck.cards where old.board == .commander {
            if let main = deck.cards.first(where: { $0.id != old.id && $0.board == .main && $0.matchKey == old.matchKey }) {
                main.quantity += old.quantity
                context.delete(old)
            } else {
                old.board = .main
            }
        }
        if card.quantity > 1 {
            card.quantity -= 1
            let commander = DeckCard(scryfallID: card.scryfallID, oracleID: card.oracleID,
                                     name: card.name, board: .commander, quantity: 1)
            commander.deck = deck
            context.insert(commander)
        } else {
            card.board = .commander
        }
        if let artCropURL { deck.coverArtURL = artCropURL }
        try touch(deck, context: context)
    }

    /// Adds copies to a board, merging with the same card (by oracle id)
    /// already on that board.
    nonisolated struct AddLine: Sendable {
        let printing: PrintingSelection
        let quantity: Int
    }

    /// Many cards onto one board as one write — a selection's Add. On the
    /// background writer: one deck fetch, the list's rows by card, one save
    /// (adding one at a time saved and bumped once per card). Returns the
    /// copies added.
    @discardableResult
    static func addMany(_ lines: [AddLine], to deckID: UUID, board: DeckBoard, context: ModelContext) async throws -> Int {
        let added = try await CardMetaWriter.shared(for: context.container).runDeckAddMany(lines, to: deckID, board: board)
        DeckChangeTracker.shared.bump()
        return added
    }

    nonisolated static func addMany(_ lines: [AddLine], to deckID: UUID, board: DeckBoard, in context: ModelContext) throws -> Int {
        guard let deck = try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == deckID })).first else { return 0 }
        var byKey: [String: DeckCard] = [:]
        for card in deck.cards where card.board == board { byKey[card.matchKey] = card }
        var added = 0
        for line in lines where line.quantity > 0 {
            let key = line.printing.oracleID ?? line.printing.scryfallID
            if let existing = byKey[key] {
                existing.quantity += line.quantity
            } else {
                let card = DeckCard(scryfallID: line.printing.scryfallID, oracleID: line.printing.oracleID,
                                    name: line.printing.name, board: board, quantity: line.quantity)
                card.deck = deck
                context.insert(card)
                byKey[key] = card
                if deck.coverArtURL == nil { deck.coverArtURL = line.printing.artCropURL }
            }
            added += line.quantity
        }
        deck.updatedDate = Date()
        try context.save()
        return added
    }

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
        let added = try importLines(lines, into: deckID, in: context)
        DeckChangeTracker.shared.bump()
        return added
    }

    /// `importLines` on a context of the caller's (a background one for a
    /// precon's hundred rows); saves, bumps nothing.
    @discardableResult
    nonisolated static func importLines(_ lines: [ResolvedDeckLine], into deckID: UUID, in context: ModelContext) throws -> Int {
        guard let deck = try context.fetch(FetchDescriptor<Deck>(predicate: #Predicate { $0.id == deckID })).first else { return 0 }
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
        deck.updatedDate = Date()
        try context.save()
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
