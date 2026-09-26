//
//  HistoryAction.swift
//  magic-hat
//
//  One user action in the History tab, aggregated off-main by
//  CollectionStore from the AuditRecords that share its actionID, with
//  where it stands in the undo/redo timeline. The `.undo` and `.redo`
//  actions themselves are not listed: they are what moves the state on
//  the actions they reverse.
//
//  Named for what it did to which cards ("Added Lightning Bolt", "Built
//  Atraxa", "Imported 3,846 Cards") rather than by kind alone: at a fork
//  two branches can both be "Added Cards", and the names are what tell
//  them apart.
//

import Foundation

nonisolated struct HistoryAction: Identifiable, Hashable, Sendable {
    let actionID: UUID
    let timestamp: Date
    let added: Int
    let removed: Int
    /// Collections touched by the action, as shown (a deck's hidden
    /// collection as "Deck: Name"). Older records also carry a source
    /// binder name; it is folded in so pre-migration history still reads.
    let scopes: [String]
    let action: AuditAction
    let state: HistoryState
    /// Distinct printings the action touched.
    let cardCount: Int
    /// Up to three of their names, the largest changes first.
    let cardNames: [String]
    /// For a deck action: the deck's name, or nil once the deck is gone.
    let deckName: String?
    /// An import that cleared the collection before adding.
    let replaced: Bool
    var id: UUID { actionID }

    init(actionID: UUID, timestamp: Date, added: Int, removed: Int, scopes: [String], action: AuditAction,
         state: HistoryState, cardCount: Int = 0, cardNames: [String] = [], deckName: String? = nil, replaced: Bool = false) {
        self.actionID = actionID
        self.timestamp = timestamp
        self.added = added
        self.removed = removed
        self.scopes = scopes
        self.action = action
        self.state = state
        self.cardCount = cardCount
        self.cardNames = cardNames
        self.deckName = deckName
        self.replaced = replaced
    }

    var isApplied: Bool { state == .applied }

    /// What was done, to what: the row's headline and the Undo/Redo
    /// label ("Undo Added Lightning Bolt").
    var title: String {
        switch action {
        case .importAdd, .importReplace:
            if replaced, let scope = scopes.first { return "Replaced \(scope)" }
            return "Imported \(cards)"
        case .manualAdd:
            return cardCount == 1 && cardNames.count == 1 ? "Added \(cardNames[0])" : "Added \(cards)"
        case .manualRemove:
            return cardCount == 1 && cardNames.count == 1 ? "Removed \(cardNames[0])" : "Removed \(cards)"
        case .deckBuild: return "Built \(deckName ?? "Deck")"
        case .deckDisassemble: return "Disassembled \(deckName ?? "Deck")"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }

    /// The second line: which cards, and where.
    var detail: String {
        var parts: [String] = []
        if let names = namesLine { parts.append(names) }
        parts.append(placeLine)
        return parts.joined(separator: " · ")
    }

    private var cards: String { cardCount == 1 ? "1 Card" : "\(cardCount.formatted()) Cards" }

    /// "Sol Ring, Arcane Signet and 58 more" when more than one card moved.
    private var namesLine: String? {
        guard cardCount > 1, !cardNames.isEmpty else { return nil }
        let shown = cardNames.prefix(2)
        let rest = cardCount - shown.count
        let names = shown.joined(separator: ", ")
        return rest > 0 ? "\(names) and \(rest.formatted()) more" : names
    }

    /// "from Main" for a build, "to Main" for a disassembly, the
    /// collections otherwise.
    private var placeLine: String {
        let deckLabel = deckName.map { "Deck: \($0)" }
        let others = scopes.filter { $0 != deckLabel && $0 != "Deleted deck" }
        switch action {
        case .deckBuild where !others.isEmpty: return "from \(others.joined(separator: ", "))"
        case .deckDisassemble where !others.isEmpty: return "to \(others.joined(separator: ", "))"
        default: return scopes.joined(separator: ", ")
        }
    }
}

/// The History tab in one value: every user action with its state, the
/// timeline that says what Undo and Redo do next, the tree as lines, and
/// the names the user gave them.
nonisolated struct HistoryLog: Hashable, Sendable {
    let actions: [HistoryAction]
    let timeline: HistoryTimeline
    /// Names by the action they were set on (a line's tip at the time).
    let names: [UUID: String]
    let lines: [HistoryLine]

    init(actions: [HistoryAction] = [], timeline: HistoryTimeline = HistoryTimeline(), names: [UUID: String] = [:]) {
        self.actions = actions
        self.timeline = timeline
        self.names = names
        self.lines = timeline.lines()
    }

    func action(_ id: UUID?) -> HistoryAction? {
        guard let id else { return nil }
        return actions.first { $0.actionID == id }
    }

    var nextUndo: HistoryAction? { action(timeline.nextUndo) }
    var nextRedo: HistoryAction? { action(timeline.nextRedo) }
    /// The ways forward from the head, the most recently taken first; more
    /// than one at a fork.
    var redoOptions: [HistoryAction] { timeline.redoOptions.compactMap(action) }

    /// How many actions lie on the branch that starts with `actionID`,
    /// following the most recently taken way at each further fork.
    func branchLength(from actionID: UUID) -> Int {
        var count = 0
        var cursor: UUID? = actionID
        while let id = cursor {
            count += 1
            let next = (timeline.children[id] ?? []).sorted { (timeline.lastVisit[$0] ?? -1) > (timeline.lastVisit[$1] ?? -1) }
            cursor = next.first
        }
        return count
    }

    // MARK: Lines

    var currentLine: HistoryLine? { lines.first { $0.isCurrent } }
    var otherLines: [HistoryLine] { lines.filter { !$0.isCurrent } }

    /// The user's name for the line: the one set nearest its tip.
    func customName(of line: HistoryLine) -> String? {
        for id in line.actions.reversed() {
            if let name = names[id] { return name }
        }
        return nil
    }

    /// The user's name, else "Timeline" for the current line and "Branch
    /// from …" (the action it leaves) for any other.
    func title(of line: HistoryLine) -> String {
        if let name = customName(of: line) { return name }
        if line.isCurrent { return "Timeline" }
        if let fork = action(line.forkFrom) { return "Branch from \(fork.title)" }
        return "Branch from the Start"
    }

    /// When anything on the line last happened.
    func latest(on line: HistoryLine) -> Date? {
        line.actions.compactMap { action($0)?.timestamp }.max()
    }
}
