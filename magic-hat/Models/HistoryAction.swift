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
    var id: UUID { actionID }

    var isApplied: Bool { state == .applied }

    /// Short name for Undo/Redo labels ("Undo Import").
    var title: String {
        switch action {
        case .importAdd, .importReplace: return "Import"
        case .manualAdd: return "Added Cards"
        case .manualRemove: return "Removed Cards"
        case .deckBuild: return "Built Deck"
        case .deckDisassemble: return "Disassembled Deck"
        case .undo: return "Undo"
        case .redo: return "Redo"
        }
    }
}

/// The History tab in one value: every user action with its state, and
/// the timeline that says what Undo and Redo do next.
nonisolated struct HistoryLog: Hashable, Sendable {
    var actions: [HistoryAction] = []
    var timeline = HistoryTimeline()

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
}
