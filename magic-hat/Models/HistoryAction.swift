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
        case .deckCreate: return "Created \(deckName ?? "Deck")"
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
        if action == .deckCreate { return "New deck · Undo removes it, Redo brings back its list" }
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
/// current line, and only the branches that hang off *the current line's*
/// drawn rows. A branch whose fork lies further back than the window is
/// not shown — a card saying "splits from" an action that isn't on screen
/// points nowhere — and comes into view with it when the window grows. A
/// branch off another branch is not shown either: it is that branch's
/// history, reached by switching to it, and its card says how many it
/// has (`Section.nested`). What is on screen is the latest history and
/// the ways off it, not every chain the ledger holds.
nonisolated struct HistoryWindow: Hashable, Sendable {
    struct Section: Hashable, Sendable, Identifiable {
        let line: HistoryLine
        /// Newest first.
        let rows: [UUID]
        /// Older actions of the line not drawn.
        let hidden: Int
        /// Branches splitting from this line, drawn only once it is current.
        var nested = 0
        var id: UUID { line.id }
    }

    let current: Section?
    let branches: [Section]
    /// Branches off the current line left out because where they split
    /// from isn't drawn yet.
    let hiddenBranches: Int

    /// The lines drawn, in order: what the list's identity is keyed on.
    var structure: [UUID] { (current.map { [$0.id] } ?? []) + branches.map(\.id) }
    /// The ids of every line drawn, for the fork tags on rows.
    var shownLines: Set<UUID> { Set(structure) }
}

nonisolated extension HistoryLog {
    /// Rows of the current line drawn before "Show Earlier".
    static let pageSize = 40
    /// Rows of another branch drawn before "Show All".
    static let branchPreview = 8

    /// `limit` rows of the current line, newest first — never fewer than
    /// reach the head, so what Undo and Redo act on is always drawn — and
    /// the branches splitting from a drawn row of it, each cut to its
    /// newest `branchPreview` rows unless its id is in `expanded`.
    func window(limit: Int = HistoryLog.pageSize, expanded: Set<UUID> = []) -> HistoryWindow {
        var drawn = Set<UUID>()
        var current: HistoryWindow.Section?
        var wholeCurrentDrawn = true
        var currentActions = Set<UUID>()
        if let line = currentLine {
            let newestFirst = Array(line.actions.reversed())
            currentActions = Set(line.actions)
            // Everything ahead of the head, the head, and one applied row
            // under it at least.
            let ahead = line.actions.count - timeline.applied.count
            let count = min(newestFirst.count, max(limit, ahead + 2))
            let rows = Array(newestFirst.prefix(count))
            drawn.formUnion(rows)
            wholeCurrentDrawn = count == newestFirst.count
            current = HistoryWindow.Section(line: line, rows: rows, hidden: newestFirst.count - count)
        }
        // How many lines hang off each other line: said on its card, drawn
        // once it is current.
        var nested: [UUID: Int] = [:]
        for line in otherLines {
            guard let fork = line.forkFrom, !currentActions.contains(fork),
                  let host = self.line(containing: fork) else { continue }
            nested[host.id, default: 0] += 1
        }
        var branches: [HistoryWindow.Section] = []
        var hiddenBranches = 0
        for line in otherLines {
            if let fork = line.forkFrom {
                // Off the current line: drawn with its fork row. Off another
                // branch: that branch's history, not this screen's.
                guard currentActions.contains(fork) else { continue }
                guard drawn.contains(fork) else { hiddenBranches += 1; continue }
            } else if !wholeCurrentDrawn {
                hiddenBranches += 1
                continue
            }
            let newestFirst = Array(line.actions.reversed())
            let count = expanded.contains(line.id) ? newestFirst.count : min(newestFirst.count, Self.branchPreview)
            let rows = Array(newestFirst.prefix(count))
            drawn.formUnion(rows)
            var section = HistoryWindow.Section(line: line, rows: rows, hidden: newestFirst.count - count)
            section.nested = nested[line.id] ?? 0
            branches.append(section)
        }
        return HistoryWindow(current: current, branches: branches, hiddenBranches: hiddenBranches)
    }
}

// MARK: - The feed

/// The History list as it scrolls: the current line's drawn rows, newest
/// first, one continuous rail — each row carrying its own date ("Today,
/// 7:58 PM", "Monday, 5:30 PM", "Oct 2, 5:30 PM"). Day cards were tried
/// and dropped: they cut the rail into pieces. Branches are not rows of
/// the feed either: the row a branch splits from wears its tag
/// (`HistoryLog.branches(from:)`) and a stub on the rail, and the tag
/// opens the branch's page. The ones that split from before the first
/// action have no row to hang from, so once the whole line is drawn they
/// are listed under it (`roots`). Older history loads at the foot.
nonisolated struct HistoryFeed: Hashable, Sendable {
    let line: HistoryLine?
    /// Every drawn row of the current line, newest first.
    let rows: [UUID]
    /// Where each of `rows` sits: every drawn row asks for its place on
    /// the rail, and `firstIndex(of:)` per row made a page of rows
    /// quadratic.
    let rowIndex: [UUID: Int]
    /// Older actions of the current line not drawn yet.
    let hidden: Int
    /// Branches off the start, listed once everything is drawn.
    let roots: [HistoryLine]
}

nonisolated extension HistoryLog {
    /// The window's current line (`window(limit:)`) as the feed.
    func feed(limit: Int = HistoryLog.pageSize) -> HistoryFeed {
        let window = window(limit: limit)
        let rows = window.current?.rows ?? []
        let rowIndex = Dictionary(rows.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let hidden = window.current?.hidden ?? 0
        let roots = hidden > 0 ? [] : otherLines.filter { $0.forkFrom == nil }
        return HistoryFeed(line: window.current?.line, rows: rows, rowIndex: rowIndex, hidden: hidden, roots: roots)
    }
}

/// A day's header: "Today", "Yesterday", the weekday within the week,
/// then "September 28", and "September 28, 2025" from another year.
nonisolated enum HistoryDayTitle {
    /// A row's own date: "Today, 7:58 PM", "Yesterday, 5:33 PM",
    /// "Monday, 5:30 PM", then "Oct 2, 5:30 PM", with the year from
    /// another year.
    static func rowDate(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(calendar.locale ?? .current)
        let time = date.formatted(style.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days >= 0, days < 7 { return "\(date.formatted(style.weekday(.wide))), \(time)" }
        var day = style.month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { day = day.year() }
        return "\(date.formatted(day)), \(time)"
    }

    static func title(for start: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(start, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(start, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: today).day ?? 0
        var style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(calendar.locale ?? .current)
        if days >= 0, days < 7 { return start.formatted(style.weekday(.wide)) }
        style = style.month(.wide).day()
        if calendar.component(.year, from: start) != calendar.component(.year, from: now) { style = style.year() }
        return start.formatted(style)
    }
}
