//
//  HistoryTimeline.swift
//  magic-hat
//
//  The undo/redo timeline, derived from the ledger. Pure and independent
//  of SwiftData so it is exhaustively testable: give it the ledger's
//  actions in order — user actions and the `.undo` / `.redo` actions that
//  reversed and re-applied them — and it says which user actions are
//  applied, which can be redone, and which an undo left behind.
//
//  The rules are UndoManager's, which is what people expect from every
//  app with an Undo menu:
//
//   - Undo reverses the most recent applied action and moves it to the
//     redo stack. Any number of times, back to the first action.
//   - Redo re-applies the most recently undone action. Any number of
//     times, forward to the last.
//   - A new user action while there is anything to redo clears the redo
//     stack: the timeline forked, and what was undone is no longer a
//     future of it. Those actions stay in the ledger — they happened —
//     as `superseded`: shown as undone, never redoable.
//
//  Ten actions, undo five: five to redo. Undo three more: eight to redo.
//  A new action: nothing to redo, those eight superseded, the timeline is
//  the first two plus the new one.
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
    /// In effect.
    case applied
    /// Reversed, and next in line (or behind others) to be redone.
    case undone
    /// Reversed, then a new action forked the timeline: shown as undone,
    /// no longer redoable.
    case superseded
}

nonisolated struct HistoryTimeline: Hashable, Sendable {
    /// Applied user actions, oldest first; `last` is what Undo reverses.
    var applied: [UUID] = []
    /// Undone user actions, oldest first; `last` is what Redo re-applies.
    var redoable: [UUID] = []
    var superseded: Set<UUID> = []

    var nextUndo: UUID? { applied.last }
    var nextRedo: UUID? { redoable.last }

    func state(of actionID: UUID) -> HistoryState {
        if superseded.contains(actionID) { return .superseded }
        if redoable.contains(actionID) { return .undone }
        return .applied
    }

    /// Replays the ledger's actions, oldest first. Steps must be in the
    /// order they happened; ties on timestamp are broken by id so the
    /// answer is deterministic.
    static func resolve(_ steps: [HistoryStep]) -> HistoryTimeline {
        var timeline = HistoryTimeline()
        let ordered = steps.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        for step in ordered {
            switch step.kind {
            case .undo:
                // Only the most recent applied action can be undone; a stray
                // record for anything else is ignored rather than trusted.
                guard let target = step.target, timeline.applied.last == target else { continue }
                timeline.applied.removeLast()
                timeline.redoable.append(target)
            case .redo:
                guard let target = step.target, timeline.redoable.last == target else { continue }
                timeline.redoable.removeLast()
                timeline.applied.append(target)
            default:
                timeline.superseded.formUnion(timeline.redoable)
                timeline.redoable.removeAll()
                timeline.applied.append(step.id)
            }
        }
        return timeline
    }

    /// The applied actions Undo would reverse, most recent first, to bring
    /// the timeline back to just before `actionID` (inclusive).
    func undoPath(through actionID: UUID) -> [UUID] {
        guard let index = applied.firstIndex(of: actionID) else { return [] }
        return Array(applied[index...].reversed())
    }

    /// The undone actions Redo would re-apply, most recently undone first,
    /// up to and including `actionID`.
    func redoPath(through actionID: UUID) -> [UUID] {
        guard let index = redoable.firstIndex(of: actionID) else { return [] }
        return Array(redoable[index...].reversed())
    }
}
