//
//  HistoryTimeline.swift
//  magic-hat
//
//  The undo/redo timeline, derived from the ledger. Pure and independent
//  of SwiftData so it is exhaustively testable: give it the ledger's
//  actions in order — user actions and the `.undo` / `.redo` actions that
//  reversed and re-applied them — and it says where the collection stands
//  and where it can go.
//
//  It is a tree, not a line. Every user action remembers its parent: the
//  action that was applied when it happened. The applied state is the path
//  from the first action to the `head`; Undo moves the head to its parent,
//  Redo to one of its children. A new action after undoing does not erase
//  what was undone — it adds a second child to the head, a fork. Undo back
//  to the fork and both branches are there to redo: the one just taken
//  (offered first, since it is the most recent) and the original one, and
//  either can be followed to its end. Nothing in the ledger is ever lost,
//  so nothing in the timeline is either.
//
//  Ten actions, undo five, do two new ones: the head is the second new
//  action; the five old ones are undone, on the other branch. Undo the
//  two: the head is back at the fifth action, which now has two children.
//  Redo, and the second new action's branch comes back; or pick the old
//  branch and redo the original five, one at a time or through to the
//  tenth.
//
//  A replay is always valid: redoing an action means the collection is in
//  exactly the state it was recorded against — its parent is applied and
//  nothing after it is — because that is the only place the head can be
//  to redo it.
//

import Foundation

/// One action as the timeline sees it.
nonisolated struct HistoryStep: Hashable, Sendable {
    let id: UUID
    let kind: AuditAction
    /// For `.undo` / `.redo`: the user action it reverses or re-applies.
    let target: UUID?
    let timestamp: Date
}

nonisolated enum HistoryState: String, Hashable, Sendable {
    /// In effect: on the path from the first action to the head.
    case applied
    /// Reversed. Redoable when its parent is the head; otherwise reached by
    /// undoing to the fork it branches from, or jumping there.
    case undone
}

nonisolated struct HistoryTimeline: Hashable, Sendable {
    /// Each user action's parent: the action applied when it happened
    /// (nil for the first action of a fresh collection).
    private(set) var parent: [UUID: UUID?] = [:]
    /// Each action's children, in the order they were first taken.
    private(set) var children: [UUID: [UUID]] = [:]
    /// Actions with no parent, in order.
    private(set) var roots: [UUID] = []
    /// The most recently applied action; nil when everything is undone.
    private(set) var head: UUID?
    /// The step index at which each action last became the head — what
    /// puts the most recently taken branch first among a fork's children.
    private(set) var lastVisit: [UUID: Int] = [:]
    /// The applied path, oldest first; `last` is the head.
    private(set) var applied: [UUID] = []

    var nextUndo: UUID? { head }

    /// The head's children, the most recently taken branch first; what Redo
    /// offers (the first is what a plain tap redoes).
    var redoOptions: [UUID] {
        let options = head.map { children[$0] ?? [] } ?? roots
        return options.sorted { (lastVisit[$0] ?? -1) > (lastVisit[$1] ?? -1) }
    }

    var nextRedo: UUID? { redoOptions.first }

    /// More than one way forward from here.
    var isFork: Bool { redoOptions.count > 1 }

    func state(of actionID: UUID) -> HistoryState {
        applied.contains(actionID) ? .applied : .undone
    }

    /// Every action the timeline knows, applied or not.
    var all: Set<UUID> { Set(parent.keys) }

    // MARK: Resolution

    /// Replays the ledger's actions, oldest first. Steps must be in the
    /// order they happened; ties on timestamp are broken by id so the
    /// answer is deterministic.
    static func resolve(_ steps: [HistoryStep]) -> HistoryTimeline {
        var t = HistoryTimeline()
        let ordered = steps.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        for (index, step) in ordered.enumerated() {
            switch step.kind {
            case .undo:
                // Only the head can be undone; a stray record for anything
                // else is ignored rather than trusted.
                guard let target = step.target, t.head == target, let p = t.parent[target] else { continue }
                t.head = p
            case .redo:
                // Only a child of the head can be redone.
                guard let target = step.target, let p = t.parent[target], p == t.head else { continue }
                t.head = target
                t.lastVisit[target] = index
            default:
                t.parent[step.id] = t.head
                if let h = t.head { t.children[h, default: []].append(step.id) } else { t.roots.append(step.id) }
                t.head = step.id
                t.lastVisit[step.id] = index
            }
        }
        t.applied = t.path(to: t.head)
        return t
    }

    /// The path from the first action down to `actionID`, oldest first.
    private func path(to actionID: UUID?) -> [UUID] {
        var out: [UUID] = []
        var cursor = actionID
        while let id = cursor {
            out.append(id)
            cursor = parent[id] ?? nil
        }
        return out.reversed()
    }

    // MARK: Paths

    /// The applied actions Undo would reverse, most recent first, to take
    /// the timeline back to just before `actionID` (inclusive).
    func undoPath(through actionID: UUID) -> [UUID] {
        guard let index = applied.firstIndex(of: actionID) else { return [] }
        return Array(applied[index...].reversed())
    }

    /// The undone actions Redo would re-apply, in order, from the head's
    /// child down to and including `actionID` — when it lies below the head.
    func redoPath(through actionID: UUID) -> [UUID] {
        guard state(of: actionID) == .undone else { return [] }
        var out: [UUID] = []
        var cursor: UUID? = actionID
        while let id = cursor {
            out.append(id)
            let p = parent[id] ?? nil
            if p == head { return out.reversed() }
            cursor = p
        }
        return []
    }

    /// How to make `actionID` the head from wherever the head is: the
    /// applied actions to undo (most recent first, down to the fork the two
    /// share) and then the actions to redo (from the fork down to and
    /// including `actionID`). Empty when it already is the head.
    func jumpPath(to actionID: UUID) -> (undos: [UUID], redos: [UUID]) {
        let targetPath = path(to: actionID)
        let targetSet = Set(targetPath)
        var undos: [UUID] = []
        var cursor = head
        while let id = cursor, !targetSet.contains(id) {
            undos.append(id)
            cursor = parent[id] ?? nil
        }
        let fork = cursor   // the deepest shared action, or nil
        let redos = targetPath.drop(while: { $0 != fork }).dropFirst()
        return (undos, fork == nil ? targetPath : Array(redos))
    }
}

// MARK: Lines

/// One chain of the tree, for showing it as a list of branches: the
/// current line (what is applied, then what Redo would take, out to a
/// leaf) and every other chain hanging off a line already placed.
nonisolated struct HistoryLine: Identifiable, Hashable, Sendable {
    /// The line's first action.
    let id: UUID
    /// The action it branches from; nil when it starts the history.
    let forkFrom: UUID?
    /// Oldest first; `last` is the tip.
    let actions: [UUID]
    let isCurrent: Bool

    var tip: UUID { actions[actions.count - 1] }
}

nonisolated extension HistoryTimeline {
    /// The tree as lines. The current line comes first; the others follow
    /// in discovery order — those forking nearest the head first, and at
    /// one fork the most recently taken first — so the list reads from
    /// where the user is outward. Every action is on exactly one line.
    func lines() -> [HistoryLine] {
        var assigned = Set<UUID>()
        var lines: [HistoryLine] = []

        func nextChild(of id: UUID?) -> UUID? {
            let options = id.map { children[$0] ?? [] } ?? roots
            return options.filter { !assigned.contains($0) }.max { (lastVisit[$0] ?? -1) < (lastVisit[$1] ?? -1) }
        }
        func chain(from start: UUID) -> [UUID] {
            var out = [start]
            assigned.insert(start)
            var cursor = start
            while let next = nextChild(of: cursor) {
                out.append(next)
                assigned.insert(next)
                cursor = next
            }
            return out
        }

        var current = applied
        assigned.formUnion(current)
        if let next = nextChild(of: head) { current += chain(from: next) }
        if let first = current.first {
            lines.append(HistoryLine(id: first, forkFrom: nil, actions: current, isCurrent: true))
        }

        // Under every placed action (nearest the tip first) and under the
        // start, each remaining child begins a line of its own.
        var frontier: [UUID?] = current.reversed().map { Optional($0) } + [nil]
        var index = 0
        while index < frontier.count {
            let node = frontier[index]
            index += 1
            while let start = nextChild(of: node) {
                let actions = chain(from: start)
                lines.append(HistoryLine(id: start, forkFrom: node, actions: actions, isCurrent: false))
                frontier.append(contentsOf: actions.reversed().map { Optional($0) })
            }
        }
        return lines
    }
}
