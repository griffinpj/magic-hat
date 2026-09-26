//
//  UndoController.swift
//  magic-hat
//
//  Undo and redo for the ledger, for the History tab (and any other screen
//  that wants an Undo button): what the next Undo and Redo would do, the
//  branches Redo can take at a fork, and the doing. The timeline comes
//  from the ledger through CollectionStore (HistoryTimeline); a replay
//  runs on CardMetaWriter's context, off the main thread — undoing an
//  import is thousands of rows — and each step is its own ledger action,
//  so a multi-step jump that fails midway leaves the collection at a step
//  boundary, never between two.
//
//  One per container, kept while the app runs, like the stores.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class UndoController {
    private(set) var log = HistoryLog()
    private(set) var isLoaded = false
    private(set) var isBusy = false
    /// Counts completed replays; views key a haptic on it.
    private(set) var completed = 0
    var error: String?

    private let container: ModelContainer

    @MainActor private static var instances: [ObjectIdentifier: UndoController] = [:]

    static func shared(for container: ModelContainer) -> UndoController {
        let key = ObjectIdentifier(container)
        if let existing = instances[key] { return existing }
        let controller = UndoController(container: container)
        instances[key] = controller
        return controller
    }

    init(container: ModelContainer) {
        self.container = container
    }

    var canUndo: Bool { !isBusy && log.timeline.nextUndo != nil }
    var canRedo: Bool { !isBusy && log.timeline.nextRedo != nil }

    /// "Undo Removed Cards", or nil when there is nothing to undo.
    var undoTitle: String? { log.nextUndo.map { "Undo \($0.title)" } }
    /// The default Redo — the most recently taken branch at a fork.
    var redoTitle: String? { log.nextRedo.map { "Redo \($0.title)" } }

    /// Reads the ledger again. Views call it when a tracker moves.
    func refresh() async {
        let store = CollectionStore.shared(for: container)
        if let fresh = try? await store.history() { log = fresh }
        isLoaded = true
    }

    /// Reverses the head.
    func undo() async {
        await perform(undos: log.timeline.nextUndo.map { [$0] } ?? [], redos: [])
    }

    /// Re-applies the head's most recently taken child.
    func redo() async {
        await perform(undos: [], redos: log.timeline.nextRedo.map { [$0] } ?? [])
    }

    /// Re-applies one particular child of the head — the other branch at a
    /// fork.
    func redo(branch actionID: UUID) async {
        guard log.timeline.redoOptions.contains(actionID) else { return }
        await perform(undos: [], redos: [actionID])
    }

    /// Reverses every applied action back to and including `actionID`.
    func undo(through actionID: UUID) async {
        await perform(undos: log.timeline.undoPath(through: actionID), redos: [])
    }

    /// Re-applies undone actions forward to and including `actionID`, when
    /// it lies below the head.
    func redo(through actionID: UUID) async {
        await perform(undos: [], redos: log.timeline.redoPath(through: actionID))
    }

    /// Makes `actionID` the head from wherever the head is: undo back to
    /// the fork the two share, then redo down the other branch.
    func jump(to actionID: UUID) async {
        let path = log.timeline.jumpPath(to: actionID)
        await perform(undos: path.undos, redos: path.redos)
    }

    private func perform(undos: [UUID], redos: [UUID]) async {
        guard !undos.isEmpty || !redos.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let writer = CardMetaWriter.shared(for: container)
        var done = 0
        do {
            for id in undos {
                try await writer.runReplay(actionID: id, direction: .undo)
                done += 1
            }
            for id in redos {
                try await writer.runReplay(actionID: id, direction: .redo)
                done += 1
            }
        } catch {
            self.error = error.localizedDescription
        }
        if done > 0 {
            completed += done
            CollectionChangeTracker.shared.bump()
            DeckChangeTracker.shared.bump()
        }
        await refresh()
    }
}
