//
//  DeckVersion.swift
//  magic-hat
//
//  A deck list's own history, git's model in a deck's words:
//
//    git                     here
//    ----------------------  ------------------------------------------
//    working tree            the deck's list (DeckCard rows), as edited
//    commit                  a Version: the whole list, saved
//    branch                  a Branch: a name pointing at its newest version
//    HEAD                    the deck's current branch (`Deck.currentBranchID`)
//    uncommitted changes     Unsaved Changes: the list against the branch's tip
//    checkout <branch>       Switch
//    checkout -b <name>      New Branch (unsaved changes come along)
//    revert to <commit>      Restore: a *new* version with the old list
//    restore .               Discard Changes
//    diff                    Compare
//
//  Two departures from git, both to keep it honest on a phone. There is no
//  detached HEAD: restoring an old version does not move back in history,
//  it saves a new version on top that holds the old list, so a branch only
//  ever grows and nothing is orphaned. And switching never refuses over
//  unsaved changes: they are saved as an automatic version on the branch
//  being left, so they are there on the way back.
//
//  A version stores the whole list (a hundred rows, a few KB), not a diff:
//  any two versions compare directly, and there is no chain to keep right.
//  As JSON, like SavedSearch's query, so the row shape can grow without a
//  migration.
//
//  This is separate from History on purpose. History is the ledger of
//  *copies* — physical cards, conserved, global, replayed by arithmetic. A
//  deck list is a wish: per deck, edited in bursts, restored by replacing
//  rows. See docs/deck-versioning.md.
//

import Foundation
import SwiftData

@Model
nonisolated final class DeckVersion {
    @Attribute(.unique) var id: UUID
    var deckID: UUID
    #Index<DeckVersion>([\.deckID])
    /// The version it was saved on top of; nil for a deck's first.
    var parentID: UUID?
    var createdAt: Date
    /// What the user called it ("Budget build"); empty when unnamed.
    var name: String
    /// "saved" (the user's) or "auto" (taken at a moment: before a switch
    /// or a restore, when the deck was built).
    var kindRaw: String
    /// For an automatic or restoring version: why it exists.
    var note: String
    /// `[DeckVersionRow]`, normalised.
    var listJSON: Data
    /// Copies on the commander and main boards.
    var cardCount: Int
    /// Copies added and removed against the parent, for the row's summary.
    var added: Int
    var removed: Int

    init(id: UUID = UUID(), deckID: UUID, parentID: UUID?, createdAt: Date = Date(), name: String = "",
         kind: Kind, note: String = "", rows: [DeckVersionRow], added: Int, removed: Int) {
        self.id = id
        self.deckID = deckID
        self.parentID = parentID
        self.createdAt = createdAt
        self.name = name
        self.kindRaw = kind.rawValue
        self.note = note
        self.listJSON = DeckVersionRow.encode(rows)
        self.cardCount = DeckVersionRow.playedCopies(rows)
        self.added = added
        self.removed = removed
    }

    enum Kind: String, Sendable { case saved, auto }
    var kind: Kind { Kind(rawValue: kindRaw) ?? .saved }
    var rows: [DeckVersionRow] { DeckVersionRow.decode(listJSON) }
}

@Model
nonisolated final class DeckBranch {
    @Attribute(.unique) var id: UUID
    var deckID: UUID
    #Index<DeckBranch>([\.deckID])
    var name: String
    /// Its newest version; nil only for a deck nothing has been saved on.
    var tipVersionID: UUID?
    var createdAt: Date

    init(id: UUID = UUID(), deckID: UUID, name: String, tipVersionID: UUID?, createdAt: Date = Date()) {
        self.id = id
        self.deckID = deckID
        self.name = name
        self.tipVersionID = tipVersionID
        self.createdAt = createdAt
    }

    static let defaultName = "Main"
}

/// One row of a saved list: what a DeckCard holds, less its identity.
nonisolated struct DeckVersionRow: Codable, Hashable, Sendable {
    var board: String
    var quantity: Int
    /// The printing the list named, for display.
    var scryfallID: String
    var oracleID: String?
    var name: String

    init(board: DeckBoard, quantity: Int, scryfallID: String, oracleID: String?, name: String) {
        self.board = board.rawValue
        self.quantity = quantity
        self.scryfallID = scryfallID
        self.oracleID = oracleID
        self.name = name
    }

    init(_ card: DeckCard) {
        self.init(board: card.board, quantity: card.quantity, scryfallID: card.scryfallID, oracleID: card.oracleID, name: card.name)
    }

    var deckBoard: DeckBoard { DeckBoard(rawValue: board) ?? .main }
    /// The card, whatever its printing — what a list is compared by.
    var cardKey: String { oracleID ?? scryfallID }
    var key: String { board + "|" + cardKey }

    /// One row per card and board, in a fixed order, so two lists that
    /// hold the same cards are equal whatever order they were built in.
    static func normalized(_ rows: [DeckVersionRow]) -> [DeckVersionRow] {
        var byKey: [String: DeckVersionRow] = [:]
        for row in rows where row.quantity > 0 {
            if var existing = byKey[row.key] { existing.quantity += row.quantity; byKey[row.key] = existing }
            else { byKey[row.key] = row }
        }
        return byKey.values.sorted { a, b in
            if a.board != b.board { return order(a.deckBoard) < order(b.deckBoard) }
            if a.name != b.name { return a.name < b.name }
            return a.cardKey < b.cardKey
        }
    }

    /// The same cards in the same numbers on the same boards — a
    /// different printing of a card is not a change to the list.
    static func sameList(_ a: [DeckVersionRow], _ b: [DeckVersionRow]) -> Bool {
        func counts(_ rows: [DeckVersionRow]) -> [String: Int] {
            var out: [String: Int] = [:]
            for row in rows where row.quantity > 0 { out[row.key, default: 0] += row.quantity }
            return out
        }
        return counts(a) == counts(b)
    }

    static func playedCopies(_ rows: [DeckVersionRow]) -> Int {
        rows.filter { $0.deckBoard.isPlayed }.reduce(0) { $0 + $1.quantity }
    }

    private static func order(_ board: DeckBoard) -> Int {
        switch board {
        case .commander: return 0
        case .main: return 1
        case .side: return 2
        case .maybe: return 3
        }
    }

    static func encode(_ rows: [DeckVersionRow]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(normalized(rows))) ?? Data("[]".utf8)
    }

    static func decode(_ data: Data) -> [DeckVersionRow] {
        (try? JSONDecoder().decode([DeckVersionRow].self, from: data)) ?? []
    }
}

// MARK: - Comparing two lists

/// One card's difference between two lists.
nonisolated struct DeckListChange: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case added
        case removed
        /// The same card on the same board, a different count.
        case count
        /// The same copies, another board.
        case moved(from: DeckBoard)
    }

    let kind: Kind
    /// The row as it is in the newer list (the older one for a removal).
    let row: DeckVersionRow
    let from: Int
    let to: Int
    var id: String { "\(row.key)|\(from)|\(to)" }
    var delta: Int { to - from }
}

nonisolated struct DeckListDiff: Hashable, Sendable {
    var changes: [DeckListChange] = []

    var isEmpty: Bool { changes.isEmpty }
    /// Copies that came in and went out; a move between boards is neither.
    var added: Int { changes.reduce(0) { sum, c in if case .moved = c.kind { return sum }; return sum + max(0, c.delta) } }
    var removed: Int { changes.reduce(0) { sum, c in if case .moved = c.kind { return sum }; return sum + max(0, -c.delta) } }
    var moved: Int { changes.reduce(0) { sum, c in if case .moved = c.kind { return sum + c.to }; return sum } }

    /// "+3 −2", "2 moved", "No changes".
    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("+\(added)") }
        if removed > 0 { parts.append("−\(removed)") }
        if moved > 0 { parts.append("\(moved) moved") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " ")
    }

    /// What changed going from `old` to `new`, by card and board. A card
    /// that left one board and joined another in the same number is one
    /// move, not a removal and an addition.
    static func between(_ old: [DeckVersionRow], _ new: [DeckVersionRow]) -> DeckListDiff {
        let before = Dictionary(DeckVersionRow.normalized(old).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(DeckVersionRow.normalized(new).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var added: [DeckListChange] = []
        var removed: [DeckListChange] = []
        var counts: [DeckListChange] = []
        for (key, row) in after {
            if let was = before[key] {
                if was.quantity != row.quantity { counts.append(DeckListChange(kind: .count, row: row, from: was.quantity, to: row.quantity)) }
            } else {
                added.append(DeckListChange(kind: .added, row: row, from: 0, to: row.quantity))
            }
        }
        for (key, row) in before where after[key] == nil {
            removed.append(DeckListChange(kind: .removed, row: row, from: row.quantity, to: 0))
        }
        // Pair a removal with an addition of the same card and count.
        var moves: [DeckListChange] = []
        var paired = Set<String>()
        for gone in removed {
            guard let i = added.firstIndex(where: { $0.row.cardKey == gone.row.cardKey && $0.to == gone.from }) else { continue }
            let arrived = added.remove(at: i)
            moves.append(DeckListChange(kind: .moved(from: gone.row.deckBoard), row: arrived.row, from: gone.from, to: arrived.to))
            paired.insert(gone.id)
        }
        removed.removeAll { paired.contains($0.id) }
        func byName(_ a: DeckListChange, _ b: DeckListChange) -> Bool {
            a.row.name != b.row.name ? a.row.name < b.row.name : a.row.key < b.row.key
        }
        return DeckListDiff(changes: added.sorted(by: byName) + removed.sorted(by: byName) + counts.sorted(by: byName) + moves.sorted(by: byName))
    }
}

// MARK: - The tree

/// The shape of a deck's versions, pure: paths, forks, what a branch owns.
nonisolated struct DeckVersionTree: Sendable {
    /// Each version's parent.
    let parent: [UUID: UUID?]

    init(parents: [(id: UUID, parent: UUID?)]) {
        parent = Dictionary(parents.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
    }

    /// `tip` and everything under it, newest first. A parent that is
    /// missing (pruned) ends the path.
    func path(from tip: UUID?) -> [UUID] {
        var out: [UUID] = []
        var seen = Set<UUID>()
        var cursor = tip
        while let id = cursor, parent[id] != nil, seen.insert(id).inserted {
            out.append(id)
            cursor = parent[id] ?? nil
        }
        return out
    }

    /// The newest version two tips share; nil when their histories don't meet.
    func mergeBase(_ a: UUID?, _ b: UUID?) -> UUID? {
        let mine = Set(path(from: a))
        return path(from: b).first { mine.contains($0) }
    }

    /// Versions no tip in `tips` reaches: what deleting a branch leaves
    /// behind, to be removed with it.
    func unreachable(from tips: [UUID?]) -> Set<UUID> {
        var reached = Set<UUID>()
        for tip in tips { reached.formUnion(path(from: tip)) }
        return Set(parent.keys).subtracting(reached)
    }
}
