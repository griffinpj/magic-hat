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

    /// The tree as lines: the current one out to what Redo would take,
    /// then each other branch, nearest the head first.
    @Test func linesFollowTheCurrentBranchAndHangTheOthersOffIt() {
        var r = Recorder()
        #expect(r.timeline.lines().isEmpty)
        let ids = (0..<10).map { _ in r.act() }
        var lines = r.timeline.lines()
        #expect(lines.count == 1 && lines[0].isCurrent && lines[0].actions == ids && lines[0].forkFrom == nil)

        for _ in 0..<5 { r.undo() }
        lines = r.timeline.lines()
        #expect(lines.count == 1 && lines[0].actions == ids, "undone actions ahead are still the one line")

        let b1 = r.act(), b2 = r.act()
        lines = r.timeline.lines()
        #expect(lines.map(\.actions) == [Array(ids[0..<5]) + [b1, b2], Array(ids[5..<10])])
        #expect(lines[1].forkFrom == ids[4] && !lines[1].isCurrent && lines[1].tip == ids[9])

        r.undo(); r.undo()
        lines = r.timeline.lines()
        #expect(lines[0].actions == Array(ids[0..<5]) + [b1, b2], "the current line runs on to what Redo would take")
        #expect(lines[1].actions == Array(ids[5..<10]))

        r.redo(ids[5])
        for _ in 0..<4 { r.redo() }
        lines = r.timeline.lines()
        #expect(lines[0].actions == ids && lines[1].actions == [b1, b2] && lines[1].forkFrom == ids[4])

        // A branch off a branch: nearest the head first, and under each
        // line its own branches, so every action is on exactly one line.
        for _ in 0..<7 { r.undo() }          // head = ids[2]
        let c1 = r.act()
        for _ in 0..<2 { r.undo() }          // head = ids[1]
        let d1 = r.act()
        lines = r.timeline.lines()
        #expect(lines.map(\.actions) == [Array(ids[0..<2]) + [d1], [ids[2], c1], Array(ids[3..<10]), [b1, b2]])
        #expect(lines.map(\.forkFrom) == [nil, ids[1], ids[2], ids[4]])
        #expect(lines.map(\.isCurrent) == [true, false, false, false])
        let all = lines.flatMap(\.actions)
        #expect(Set(all) == r.timeline.all && all.count == r.timeline.all.count)
    }

    @Test func aForkAtTheStartIsALineFromNothing() {
        var r = Recorder()
        let a = r.act()
        r.undo()
        let b = r.act()
        let lines = r.timeline.lines()
        #expect(lines.map(\.actions) == [[b], [a]])
        #expect(lines[1].forkFrom == nil && !lines[1].isCurrent)
    }

    /// Add, undo it, add something else: the new action is on the current
    /// line once, the undone one is its own branch, and nothing is listed
    /// twice — whether the fork is on an earlier action or at the start.
    @Test func anUndoneActionFollowedByANewOneIsListedOnceEach() {
        var r = Recorder()
        let first = r.act()
        let scanned = r.act()
        r.undo()
        let added = r.act()
        let lines = r.timeline.lines()
        #expect(lines.map(\.actions) == [[first, added], [scanned]])
        #expect(lines[1].forkFrom == first)
        #expect(r.timeline.state(of: scanned) == .undone && r.timeline.state(of: added) == .applied)
        let window = HistoryLog(timeline: r.timeline).window()
        #expect(window.current?.rows == [added, first] && window.branches.map(\.rows) == [[scanned]])
        #expect((window.current!.rows + window.branches.flatMap(\.rows)).count == 3, "three actions, three rows")
    }

    /// The list as it scrolls: the current line by day, newest first, and
    /// each branch right after the row it splits from (the day carrying on
    /// below it) — never below the foot of the line, where loading more
    /// would push it out of reach. The load-more row is last of all.
    @Test func theFeedGroupsTheLineByDayAndPutsEachBranchAfterItsFork() {
        var r = Recorder()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        r.clock = Date(timeIntervalSince1970: 1_790_000_000)    // a morning, UTC
        let a = r.act(), b = r.act()
        r.clock += 86_400
        let c = r.act(), d = r.act()
        r.undo()                                                 // d: a branch off c
        let x = r.act(), y = r.act()
        r.clock += 86_400
        let e = r.act()
        let timeline = r.timeline
        let actions = r.steps.filter { $0.kind.isUserAction }.map {
            HistoryAction(actionID: $0.id, timestamp: $0.timestamp, added: 1, removed: 0, scopes: [], action: .manualAdd,
                          state: timeline.state(of: $0.id))
        }
        let log = HistoryLog(actions: actions, timeline: timeline)
        let feed = log.feed(calendar: calendar)
        #expect(feed.currentRows == [e, y, x, c, b, a])
        #expect(feed.currentRows.enumerated().allSatisfy { feed.rowIndex[$1] == $0 }, "each row's place on the rail, by lookup")
        #expect(timeline.appliedSet == Set(timeline.applied) && timeline.applied.last == timeline.head)
        #expect(timeline.state(of: d) == .undone && timeline.state(of: e) == .applied)

        // Search: by title, by the ledger's matches, by day, newest first.
        let found = HistorySearchResults(needle: "nothing-matches", actions: actions, matches: [a, e], calendar: calendar)
        #expect(found.days.map(\.actions) == [[e], [a]])
        func shape(_ feed: HistoryFeed) -> [String] {
            feed.blocks.map { block in
                switch block {
                case .day(let day): return (day.showsHeader ? "day " : "… ") + day.rows.map { String($0.uuidString.prefix(4)) }.joined(separator: ",")
                case .branch(let section): return "branch " + section.rows.map { String($0.uuidString.prefix(4)) }.joined(separator: ",")
                case .more: return "more"
                }
            }
        }
        func ids(_ list: [UUID]) -> String { list.map { String($0.uuidString.prefix(4)) }.joined(separator: ",") }
        #expect(shape(feed) == ["day " + ids([e]), "day " + ids([y, x, c]), "branch " + ids([d]), "day " + ids([b, a])],
                "the branch off c follows c; c is the last of its day, so the next card is the day before")
        guard case .day(let newest) = feed.blocks.first else { Issue.record("a day first"); return }
        #expect(newest.isNewest && feed.hidden == 0 && feed.hiddenBranches == 0)

        // Cut to three rows: the fork isn't drawn, so neither is its branch,
        // and the load-more row closes the list, under nothing.
        let cut = log.feed(limit: 3, calendar: calendar)
        #expect(cut.currentRows == [e, y, x] && cut.hidden == 3 && cut.hiddenBranches == 1)
        #expect(shape(cut) == ["day " + ids([e]), "day " + ids([y, x]), "more"])

        // A fork in the middle of a day: the day carries on under the
        // branch's card, without its header again.
        var m = Recorder()
        m.clock = Date(timeIntervalSince1970: 1_790_000_000)
        let first = m.act(), p = m.act(), q = m.act(), s = m.act()
        m.undo(); m.undo()                                        // q, s: a branch off p
        let t = m.act(), u = m.act()
        let mt = m.timeline
        let mActions = m.steps.filter { $0.kind.isUserAction }.map {
            HistoryAction(actionID: $0.id, timestamp: $0.timestamp, added: 1, removed: 0, scopes: [], action: .manualAdd,
                          state: mt.state(of: $0.id))
        }
        let mid = HistoryLog(actions: mActions, timeline: mt).feed(calendar: calendar)
        #expect(shape(mid) == ["day " + ids([u, t, p]), "branch " + ids([s, q]), "… " + ids([first])])
    }

    @Test func dayHeadersReadLikeMail() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_791_288_000)    // Tue 6 Oct 2026, 12:00 UTC
        func ago(_ days: Double) -> Date { now - days * 86_400 }
        #expect(HistoryDayTitle.title(for: ago(0), now: now, calendar: calendar) == "Today")
        #expect(HistoryDayTitle.title(for: ago(1), now: now, calendar: calendar) == "Yesterday")
        #expect(HistoryDayTitle.title(for: ago(3), now: now, calendar: calendar) == "Saturday")
        #expect(HistoryDayTitle.title(for: ago(10), now: now, calendar: calendar) == "September 26")
        #expect(HistoryDayTitle.title(for: ago(375), now: now, calendar: calendar) == "September 26, 2025")
    }

    @Test func aLongHistoryIsCutAndBranchesOffTheCutPartAreHidden() {
        var r = Recorder()
        let ids = (0..<100).map { _ in r.act() }
        // A branch far back (off action 10) and one near the head (off 95).
        for _ in 0..<89 { r.undo() }
        let old = r.act()
        r.undo()
        r.redo(ids[11])
        for _ in 0..<84 { r.redo() }          // head = ids[95]
        let near = (0..<12).map { _ in r.act() }
        for _ in 0..<12 { r.undo() }
        r.redo(ids[96])
        for _ in 0..<3 { r.redo() }           // head = ids[99]
        let log = HistoryLog(timeline: r.timeline)
        #expect(log.lines.count == 3)

        let window = log.window(limit: 40)
        #expect(window.current?.rows.count == 40 && window.current?.rows.first == ids[99] && window.current?.hidden == 60)
        #expect(window.branches.map(\.id) == [near[0]], "only the branch whose fork is drawn")
        #expect(window.branches[0].rows == Array(near.reversed().prefix(HistoryLog.branchPreview)) && window.branches[0].hidden == 4)
        #expect(window.hiddenBranches == 1)

        let expanded = log.window(limit: 40, expanded: [near[0]])
        #expect(expanded.branches[0].rows.count == 12 && expanded.branches[0].hidden == 0)

        let all = log.window(limit: 100)
        #expect(all.current?.hidden == 0 && all.hiddenBranches == 0)
        #expect(all.branches.map(\.id) == [near[0], old])

        // Far back on the timeline with a long redo ahead: the head is drawn.
        for _ in 0..<90 { r.undo() }
        let back = HistoryLog(timeline: r.timeline).window(limit: 40)
        #expect(back.current?.rows.contains(r.timeline.head!) == true)
        #expect(back.current?.rows.count == 92, "ninety to redo, the head, and one under it")
    }

    /// A branch off another branch is that branch's history: the window
    /// leaves it out and counts it on its host's card; switched to the
    /// host, it is drawn.
    @Test func aBranchOffABranchWaitsForItsHost() {
        var r = Recorder()
        let a = r.act(), b = r.act(), c = r.act()
        r.undo(); r.undo()                      // head a
        let d = r.act()                         // [a, d]; [b, c] off a
        r.undo(); r.redo(b)                     // head b
        let e = r.act()                         // [a, b, e]; [c] off b; [d] off a
        r.undo(); r.undo(); r.redo(d)           // head d: current [a, d]
        let log = HistoryLog(timeline: r.timeline)
        let lines = log.lines
        #expect(lines.map(\.actions) == [[a, d], [b, e], [c]], "e was visited last, so b's line runs to it; c hangs off b")

        let window = log.window()
        #expect(window.branches.map(\.id) == [b], "only the branch off the current line")
        #expect(window.branches[0].nested == 1, "its card counts the branch it has")
        #expect(window.hiddenBranches == 0, "a nested branch is not 'hidden earlier'")
        #expect(window.shownLines == [a, b])

        r.undo(); r.redo(b); r.redo(e)          // switch to [a, b, e]
        let switched = HistoryLog(timeline: r.timeline).window()
        #expect(switched.current?.line.actions == [a, b, e])
        #expect(Set(switched.branches.map(\.id)) == [c, d], "both hang off the current line now")
        _ = c
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
