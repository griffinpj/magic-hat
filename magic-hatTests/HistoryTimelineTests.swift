import Testing
import Foundation
@testable import magic_hat

/// The timeline's rules, on a ledger built step by step: undo any number
/// of times, redo any number of times, and a new action after an undo
/// forks the timeline — what was undone is superseded, never redoable.
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
            let target = timeline.nextUndo
            steps.append(HistoryStep(id: UUID(), kind: .undo, target: target, timestamp: clock))
            clock += 1
        }

        mutating func redo() {
            let target = timeline.nextRedo
            steps.append(HistoryStep(id: UUID(), kind: .redo, target: target, timestamp: clock))
            clock += 1
        }

        var timeline: HistoryTimeline { .resolve(steps) }
    }

    @Test func tenActionsUndoFiveRedoFive() {
        var r = Recorder()
        let ids = (0..<10).map { _ in r.act() }
        #expect(r.timeline.applied == ids && r.timeline.redoable.isEmpty)

        for _ in 0..<5 { r.undo() }
        #expect(r.timeline.applied == Array(ids[0..<5]))
        #expect(r.timeline.redoable == Array(ids[5..<10].reversed()), "most recently undone last, so it redoes first")
        #expect(r.timeline.nextRedo == ids[5] && r.timeline.nextUndo == ids[4])

        for _ in 0..<5 { r.redo() }
        #expect(r.timeline.applied == ids && r.timeline.redoable.isEmpty)
        #expect(r.timeline.superseded.isEmpty)
        #expect(ids.allSatisfy { r.timeline.state(of: $0) == .applied })
    }

    @Test func aNewActionAfterUndoingForksTheTimeline() {
        var r = Recorder()
        let ids = (0..<10).map { _ in r.act() }
        for _ in 0..<5 { r.undo() }
        for _ in 0..<5 { r.redo() }
        for _ in 0..<3 { r.undo() }
        #expect(r.timeline.redoable.count == 3 && r.timeline.applied.count == 7)

        // The lynchpin: a new action while there is something to redo.
        let fresh = r.act()
        #expect(r.timeline.redoable.isEmpty, "nothing to redo once the timeline forked")
        #expect(r.timeline.nextRedo == nil)
        #expect(r.timeline.applied == Array(ids[0..<7]) + [fresh])
        #expect(r.timeline.superseded == Set(ids[7..<10]))
        #expect(r.timeline.state(of: ids[9]) == .superseded)
        #expect(r.timeline.state(of: fresh) == .applied)

        // A redo recorded against a superseded action is ignored, not obeyed.
        r.steps.append(HistoryStep(id: UUID(), kind: .redo, target: ids[9], timestamp: r.clock))
        #expect(r.timeline.applied == Array(ids[0..<7]) + [fresh])

        // Undo keeps going through the fork, back to nothing.
        for _ in 0..<8 { r.undo() }
        #expect(r.timeline.applied.isEmpty && r.timeline.nextUndo == nil)
        #expect(r.timeline.redoable.count == 8)
        for _ in 0..<8 { r.redo() }
        #expect(r.timeline.applied == Array(ids[0..<7]) + [fresh])
    }

    @Test func undoOfAnythingButTheLatestIsIgnored() {
        var r = Recorder()
        let a = r.act(), b = r.act()
        r.steps.append(HistoryStep(id: UUID(), kind: .undo, target: a, timestamp: r.clock))
        #expect(r.timeline.applied == [a, b], "a stray undo of an earlier action changes nothing")
        r.steps.append(HistoryStep(id: UUID(), kind: .undo, target: nil, timestamp: r.clock))
        #expect(r.timeline.applied == [a, b])
    }

    @Test func pathsForMultiStepJumps() {
        var r = Recorder()
        let ids = (0..<5).map { _ in r.act() }
        #expect(r.timeline.undoPath(through: ids[2]) == [ids[4], ids[3], ids[2]], "most recent first, through the one asked for")
        for _ in 0..<4 { r.undo() }
        #expect(r.timeline.redoPath(through: ids[3]) == [ids[1], ids[2], ids[3]])
        #expect(r.timeline.redoPath(through: ids[0]).isEmpty, "still applied: nothing to redo")
        #expect(r.timeline.undoPath(through: ids[4]).isEmpty, "undone: nothing to undo")
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
        #expect(ordered.superseded == Set(ids[4..<6]))
    }
}
