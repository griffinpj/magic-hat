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
    /// For a move: where the copies went.
    var destination: String? = nil
    /// The scopes that are lists (wanted, not owned). Putting cards on a
    /// list and adding the same cards to a collection are otherwise the
    /// same title and the same count — two rows that read as a duplicate.
    var listScopes: Set<String> = []
    /// Every copy it touched is on a list: nothing owned changed.
    var isListOnly: Bool { !scopes.isEmpty && scopes.allSatisfy(listScopes.contains) }
    var id: UUID { actionID }

    init(actionID: UUID, timestamp: Date, added: Int, removed: Int, scopes: [String], action: AuditAction,
         state: HistoryState, cardCount: Int = 0, cardNames: [String] = [], deckName: String? = nil, replaced: Bool = false,
         destination: String? = nil, listScopes: Set<String> = []) {
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
        self.destination = destination
        self.listScopes = listScopes
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
        case .deckDelete: return "Deleted \(deckName ?? "Deck")"
        case .move:
            return cardCount == 1 && cardNames.count == 1 ? "Moved \(cardNames[0])" : "Moved \(cards)"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }

    /// The second line: where, then which cards. The place leads because
    /// the line is cut at the row's width, and the place is what tells two
    /// actions on the same cards apart ("Wants (list)" against "Main").
    var detail: String {
        var parts: [String] = [placeLine]
        if let names = namesLine { parts.append(names) }
        return parts.joined(separator: " · ")
    }

    private func shown(_ scope: String) -> String { listScopes.contains(scope) ? "\(scope) (list)" : scope }

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
        if action == .deckDelete { return "Deck · its list and versions come back with Undo" }
        let deckLabel = deckName.map { "Deck: \($0)" }
        let others = scopes.filter { $0 != deckLabel && $0 != "Deleted deck" }
        switch action {
        case .deckBuild where !others.isEmpty: return "from \(others.map(shown).joined(separator: ", "))"
        case .deckDisassemble where !others.isEmpty: return "to \(others.map(shown).joined(separator: ", "))"
        case .move:
            guard let destination else { return scopes.map(shown).joined(separator: ", ") }
            let from = scopes.filter { $0 != destination }
            return from.isEmpty ? "to \(shown(destination))" : "\(from.map(shown).joined(separator: ", ")) → \(shown(destination))"
        default: return scopes.map(shown).joined(separator: ", ")
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
    /// Why the next Undo, or a Redo on offer, can't run as things stand
    /// (a deck that is gone, copies no longer there), by action — checked
    /// when the log is read, so the row and the button say it up front.
    let blocked: [UUID: String]
    /// Where each action sits in `actions`: a row looks its action up, and
    /// a scan per row made a long history quadratic.
    private let index: [UUID: Int]

    init(actions: [HistoryAction] = [], timeline: HistoryTimeline = HistoryTimeline(), names: [UUID: String] = [:],
         blocked: [UUID: String] = [:]) {
        self.blocked = blocked
        self.actions = actions
        self.timeline = timeline
        self.names = names
        self.lines = timeline.lines()
        self.index = Dictionary(actions.enumerated().map { ($1.actionID, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func action(_ id: UUID?) -> HistoryAction? {
        guard let id, let i = index[id] else { return nil }
        return actions[i]
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

    /// The user's name, else "Timeline" for the current line and, for any
    /// other, what it starts with ("Removed Sol Ring and 2 more"). Where
    /// it hangs is the junction row's job, not the name's.
    func title(of line: HistoryLine) -> String {
        if let name = customName(of: line) { return name }
        if line.isCurrent { return "Timeline" }
        guard let first = action(line.id) else { return "Branch" }
        let more = line.actions.count - 1
        return more == 0 ? first.title : "\(first.title) and \(more) more"
    }

    /// The line an action is on.
    func line(containing actionID: UUID?) -> HistoryLine? {
        guard let actionID else { return nil }
        return lines.first { $0.actions.contains(actionID) }
    }

    /// The lines that split off right after `actionID`.
    func branches(from actionID: UUID) -> [HistoryLine] {
        lines.filter { $0.forkFrom == actionID }
    }

    /// What switching to the line does: actions undone back to the fork,
    /// actions redone up the line.
    func switchCost(of line: HistoryLine) -> (back: Int, forward: Int) {
        let path = timeline.jumpPath(to: line.tip)
        return (path.undos.count, path.redos.count)
    }

    /// When anything on the line last happened.
    func latest(on line: HistoryLine) -> Date? {
        line.actions.compactMap { action($0)?.timestamp }.max()
    }
}

// MARK: - The window a long history is shown through

/// What the History list draws of a long history: the newest part of the
/// current line, and only the branches that hang off something drawn. A
/// branch whose fork lies further back than the window is not shown — a
/// card saying "splits from" an action that isn't on screen points
/// nowhere — and comes into view with it when the window grows.
nonisolated struct HistoryWindow: Hashable, Sendable {
    struct Section: Hashable, Sendable, Identifiable {
        let line: HistoryLine
        /// Newest first.
        let rows: [UUID]
        /// Older actions of the line not drawn.
        let hidden: Int
        var id: UUID { line.id }
    }

    let current: Section?
    let branches: [Section]
    /// Branches left out because where they split from isn't drawn.
    let hiddenBranches: Int

    /// The lines drawn, in order: what the list's identity is keyed on.
    var structure: [UUID] { (current.map { [$0.id] } ?? []) + branches.map(\.id) }
}

nonisolated extension HistoryLog {
    /// Rows of the current line drawn before "Show Earlier".
    static let pageSize = 40
    /// Rows of another branch drawn before "Show All".
    static let branchPreview = 8

    /// `limit` rows of the current line, newest first — never fewer than
    /// reach the head, so what Undo and Redo act on is always drawn — and
    /// the branches splitting from a drawn row, each cut to its newest
    /// `branchPreview` rows unless its id is in `expanded`.
    func window(limit: Int = HistoryLog.pageSize, expanded: Set<UUID> = []) -> HistoryWindow {
        var drawn = Set<UUID>()
        var current: HistoryWindow.Section?
        var wholeCurrentDrawn = true
        if let line = currentLine {
            let newestFirst = Array(line.actions.reversed())
            // Everything ahead of the head, the head, and one applied row
            // under it at least.
            let ahead = line.actions.count - timeline.applied.count
            let count = min(newestFirst.count, max(limit, ahead + 2))
            let rows = Array(newestFirst.prefix(count))
            drawn.formUnion(rows)
            wholeCurrentDrawn = count == newestFirst.count
            current = HistoryWindow.Section(line: line, rows: rows, hidden: newestFirst.count - count)
        }
        var branches: [HistoryWindow.Section] = []
        var hiddenBranches = 0
        // `otherLines` lists a branch after the line it hangs from, so one
        // pass sees a branch's host before the branch.
        for line in otherLines {
            let anchored: Bool
            if let fork = line.forkFrom { anchored = drawn.contains(fork) } else { anchored = wholeCurrentDrawn }
            guard anchored else { hiddenBranches += 1; continue }
            let newestFirst = Array(line.actions.reversed())
            let count = expanded.contains(line.id) ? newestFirst.count : min(newestFirst.count, Self.branchPreview)
            let rows = Array(newestFirst.prefix(count))
            drawn.formUnion(rows)
            branches.append(HistoryWindow.Section(line: line, rows: rows, hidden: newestFirst.count - count))
        }
        return HistoryWindow(current: current, branches: branches, hiddenBranches: hiddenBranches)
    }
}
