import Testing
import Foundation
@testable import magic_hat

/// The timeline's rules, on a ledger built step by step: undo any number
/// of times, redo any number of times, and a new action after an undo
/// forks the timeline — both branches stay, and undoing back to the fork
/// lets either be redone.
@Suite("HistoryTimeline")
struct HistoryTimelineTests {
    /// A ledger recorder: user actions and the undo/redo actions that
    /// reverse them, each a second apart.
    struct Recorder {
        var steps: [HistoryStep] = []
        var clock = Date(timeIntervalSince1970: 1_000_000)

        mutating func act() -> UUID {
            let id = UUID()
            steps.append(HistoryStep(id: id, kind: .manualAdd, target: nil, timestamp: clock))
            clock += 1
            return id
        }

        mutating func undo() {
            steps.append(HistoryStep(id: UUID(), kind: .undo, target: timeline.nextUndo, timestamp: clock))
            clock += 1
        }

        /// Redo the given child of the head, or the default (most recent).
        mutating func redo(_ target: UUID? = nil) {
            steps.append(HistoryStep(id: UUID(), kind: .redo, target: target ?? timeline.nextRedo, timestamp: clock))
            clock += 1
        }

        var timeline: HistoryTimeline { .resolve(steps) }
    }

    @Test func tenActionsUndoFiveRedoFive() {
        var r = Recorder()
        let ids = (0..<10).map { _ in r.act() }
        #expect(r.timeline.applied == ids && r.timeline.redoOptions.isEmpty)

        for _ in 0..<5 { r.undo() }
        #expect(r.timeline.applied == Array(ids[0..<5]))
        #expect(r.timeline.head == ids[4] && r.timeline.nextUndo == ids[4])
        #expect(r.timeline.redoOptions == [ids[5]], "one way forward: the action after the head")
        #expect(ids[5..<10].allSatisfy { r.timeline.state(of: $0) == .undone })

        for _ in 0..<5 { r.redo() }
        #expect(r.timeline.applied == ids && r.timeline.redoOptions.isEmpty)
        #expect(ids.allSatisfy { r.timeline.state(of: $0) == .applied })
    }

    /// Ten actions, undo five, two new ones, undo those two: back at the
    /// fork, both branches are there, and the original can be followed
    /// through to the tenth.
    @Test func undoingBackToTheForkRegainsTheOriginalBranch() {
        var r = Recorder()
        let ids = (0..<10).map { _ in r.act() }
        for _ in 0..<5 { r.undo() }
        let b1 = r.act()
        let b2 = r.act()
        #expect(r.timeline.applied == Array(ids[0..<5]) + [b1, b2])
        #expect(r.timeline.redoOptions.isEmpty, "nothing to redo from the new head")
        #expect(ids[5..<10].allSatisfy { r.timeline.state(of: $0) == .undone }, "the old branch is undone, not gone")

        r.undo(); r.undo()
        #expect(r.timeline.head == ids[4])
        #expect(r.timeline.isFork)
        #expect(r.timeline.redoOptions == [b1, ids[5]], "the branch just taken first, then the original")
        #expect(r.timeline.nextRedo == b1, "a plain Redo takes the recent branch")

        // The original branch, all the way.
        r.redo(ids[5])
        #expect(r.timeline.head == ids[5] && r.timeline.redoOptions == [ids[6]])
        for _ in 0..<4 { r.redo() }
        #expect(r.timeline.applied == ids, "the original ten, intact")
        #expect(r.timeline.state(of: b1) == .undone && r.timeline.state(of: b2) == .undone)

        // And the other way again: at the fork, the original branch is now
        // the most recent, so it is the default.
        for _ in 0..<5 { r.undo() }
        #expect(r.timeline.redoOptions == [ids[5], b1])
        r.redo(b1); r.redo()
        #expect(r.timeline.applied == Array(ids[0..<5]) + [b1, b2])
    }

    @Test func redoOfAnythingButAChildOfTheHeadIsIgnored() {
        var r = Recorder()
        let ids = (0..<4).map { _ in r.act() }
        for _ in 0..<3 { r.undo() }
        r.redo(ids[3])   // two below the head: not a child
        #expect(r.timeline.applied == [ids[0]])
        r.steps.append(HistoryStep(id: UUID(), kind: .undo, target: ids[3], timestamp: r.clock))
        #expect(r.timeline.applied == [ids[0]], "a stray undo of a non-head changes nothing")
        r.steps.append(HistoryStep(id: UUID(), kind: .undo, target: nil, timestamp: r.clock))
        #expect(r.timeline.applied == [ids[0]])
    }

    @Test func pathsForMultiStepJumps() {
        var r = Recorder()
        let ids = (0..<5).map { _ in r.act() }
        #expect(r.timeline.undoPath(through: ids[2]) == [ids[4], ids[3], ids[2]], "most recent first, through the one asked for")
        for _ in 0..<4 { r.undo() }
        #expect(r.timeline.redoPath(through: ids[3]) == [ids[1], ids[2], ids[3]])
        #expect(r.timeline.redoPath(through: ids[0]).isEmpty, "still applied: nothing to redo")
        #expect(r.timeline.undoPath(through: ids[4]).isEmpty, "undone: nothing to undo")

        // A fork, and a jump across it: undo to the shared action, redo down.
        let b1 = r.act(), b2 = r.act()
        #expect(r.timeline.redoPath(through: ids[3]).isEmpty, "the other branch is not below the head")
        #expect(r.timeline.jumpPath(to: ids[3]) == ([b2, b1], [ids[1], ids[2], ids[3]]))
        #expect(r.timeline.jumpPath(to: b2) == ([], []), "already the head")
        #expect(r.timeline.jumpPath(to: ids[0]) == ([b2, b1], []), "an applied ancestor: only undos")
        r.undo(); r.undo(); r.redo(ids[1]); r.redo()
        #expect(r.timeline.jumpPath(to: b2) == ([ids[2], ids[1]], [b1, b2]))
    }

    @Test func aWholeEmptyTimelineForksAtTheRoot() {
        var r = Recorder()
        let a = r.act()
        r.undo()
        #expect(r.timeline.head == nil && r.timeline.redoOptions == [a])
        let b = r.act()
        r.undo()
        #expect(r.timeline.redoOptions == [b, a], "two first actions: both ways forward from nothing")
        #expect(r.timeline.jumpPath(to: a) == ([], [a]))
        r.redo(a)
        #expect(r.timeline.applied == [a])
    }

    @Test func resolutionDoesNotDependOnInputOrder() {
        var r = Recorder()
        let ids = (0..<6).map { _ in r.act() }
        for _ in 0..<2 { r.undo() }
        _ = r.act()
        r.undo()
        let ordered = r.timeline
        let shuffled = HistoryTimeline.resolve(r.steps.shuffled())
        #expect(shuffled == ordered)
        #expect(ordered.redoOptions.count == 2 && ordered.redoOptions.last == ids[4])
    }
}
