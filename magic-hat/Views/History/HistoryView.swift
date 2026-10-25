//
//  HistoryView.swift
//  magic-hat
//
//  The append-only audit ledger grouped by action, newest first — each
//  import, edit, build or disassembly as one row — and the way back: Undo
//  and Redo in the bar, as Notes and Freeform place them, each disabled
//  when there is nothing to do and named for what it would do ("Undo
//  Removed Cards"), with ⌘Z / ⇧⌘Z on a keyboard. Any number of steps in
//  either direction.
//
//  One chronological list: the current line — what is applied, and above
//  it, dimmed, what Redo would take — by day, "Today", "Yesterday",
//  "Monday", "September 28", each day its own card (Mail's and Photos'
//  landmarks in a long stream), with a rail in the gutter (HistoryRail)
//  that says which rows stand and where the head is. The timeline is a
//  tree (see HistoryTimeline), but the tree is not drawn here: the row a
//  branch leaves from wears one tag naming it, and the tag opens the
//  branch's own page (HistoryBranchView) — its actions, what it splits
//  from, Switch as the one prominent button. The feed used to interleave
//  every branch as a card of its own between the day cards, each with a
//  header, a Switch, a menu and a junction row, and a fork was drawn three
//  times over; the timeline read as cut into pieces.
//
//  At a fork the Redo button opens a menu of the branches on tap (Mail's
//  reply arrow: one control, several outcomes) — no hidden gesture, no
//  sheet. Any row pushes its detail: the cards it changed, and the one
//  button that undoes, redoes or switches to it. Older history loads as
//  the foot of the list comes into view (HistoryWindow: forty actions at
//  a time). Search finds an action by any card it touched (an import's
//  thousands, not only the names a row shows), a collection or a deck.
//
//  No @Query: the ledger is a large table, and a query over it re-ran on
//  the main thread after every background save (each hydration batch).
//  CollectionStore groups it off-main; the view refetches when a write
//  bumps a tracker.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    private var tracker: CollectionChangeTracker { .shared }
    private var undo: UndoController { .shared(for: modelContext.container) }
    /// Typed, so a branch's page can be taken out from under the detail
    /// pushed over it once the branch is switched to (`prune`): a view
    /// can't dismiss itself from the middle of a stack.
    @State private var path: [HistoryRoute] = []
    @State private var showGuide = false
    /// How much of the current line is drawn.
    @State private var shownLimit = HistoryLog.pageSize
    @State private var query = ""
    /// What the search found, worked out in the debounced task below —
    /// the ledger's answer plus every action's title and detail matched
    /// off the main actor — never in the body, where it ran per keystroke.
    @State private var found = HistorySearchResults()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !undo.isLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if undo.log.actions.isEmpty {
                    ContentUnavailableView(
                        "No History",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Imports and changes to your collection appear here.")
                    )
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    results
                } else {
                    list
                }
            }
            .navigationTitle("History")
            // "3 applied · 2 to redo", led by the line's name when it has
            // one: what the Timeline header used to say, without a header.
            .navigationSubtitle(undo.isLoaded && !undo.log.actions.isEmpty ? subtitle : "")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Cards, collections, decks")
            .task(id: "\(query)|\(undo.revision)") {
                let needle = query.trimmingCharacters(in: .whitespaces)
                guard !needle.isEmpty else { return }
                // A pause before asking the ledger, as typing goes on.
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                let matches = await undo.matches(needle)
                let actions = undo.log.actions
                let results = await Task.detached(priority: .userInitiated) {
                    HistorySearchResults(needle: needle, actions: actions, matches: matches)
                }.value
                guard !Task.isCancelled else { return }
                found = results
            }
            .navigationDestination(for: HistoryRoute.self) { route in
                switch route {
                case .detail(let id): HistoryDetailView(actionID: id)
                case .branch(let id): HistoryBranchView(lineID: id, onOpenBranch: open)
                }
            }
            .onChange(of: undo.revision) { _, _ in prune() }
            .toolbar { toolbar }
            .sheet(isPresented: $showGuide) { HistoryGuideView() }
            // The ledger's tracker alone: deck list edits write no records,
            // and the whole ledger was re-read on every stepper tap once
            // this tab had been opened. Creating, deleting and renaming a
            // deck bump it too.
            .task(id: tracker.revision) { await undo.refresh() }
            .sensoryFeedback(.success, trigger: undo.completed)
            // ⇧⌘Z at a fork: the Redo control is a menu then, which takes
            // no shortcut, so a hidden button redoes the default branch —
            // the most recently taken, what a plain Redo would take.
            .background {
                if undo.log.timeline.isFork {
                    Button("Redo") { Task { await undo.redo() } }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!undo.canRedo)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .alert("Couldn't Change That", isPresented: Binding(get: { undo.error != nil }, set: { if !$0 { undo.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(undo.error ?? "")
            }
        }
    }

    /// "Side quest · 3 applied · 2 to redo".
    private var subtitle: String {
        let applied = undo.log.timeline.applied.count
        var parts: [String] = []
        if let line = undo.log.currentLine, let name = undo.log.customName(of: line) { parts.append(name) }
        parts.append(applied == 1 ? "1 applied" : "\(applied.formatted()) applied")
        if let line = undo.log.currentLine {
            let ahead = line.actions.count - applied
            if ahead > 0 { parts.append(ahead == 1 ? "1 to redo" : "\(ahead) to redo") }
        }
        return parts.joined(separator: " · ")
    }

    private func open(_ line: HistoryLine) {
        path.append(.branch(line.id))
    }

    /// A branch page whose branch is now the timeline (switched to here,
    /// from a row's detail, or from Redo's menu) has nothing to show:
    /// taken off the stack, whatever sits above it stays.
    private func prune() {
        let lines = undo.log.lines
        path.removeAll { route in
            guard case .branch(let id) = route else { return false }
            return !lines.contains { $0.id == id && !$0.isCurrent }
        }
    }

    // MARK: List

    private var list: some View {
        let feed = undo.log.feed(limit: shownLimit)
        return List {
            ForEach(feed.blocks) { block in
                switch block {
                case .day(let day):
                    daySection(day, feed: feed)
                case .roots(let lines):
                    rootsSection(lines)
                case .more:
                    Section { earlierRow(hidden: feed.hidden) }
                }
            }
        }
        .listStyle(.insetGrouped)
        // Keyed on the read, not the log: comparing every action of a long
        // history ran on each render.
        .animation(.default, value: undo.revision)
        .overlay(alignment: .bottom) {
            if undo.isBusy { busyPill }
        }
        .animation(.default, value: undo.isBusy)
    }

    /// One day of the current line: its rows on the rail, under the day's
    /// header.
    private func daySection(_ day: HistoryFeed.Day, feed: HistoryFeed) -> some View {
        Section {
            ForEach(day.rows, id: \.self) { id in
                if let action = undo.log.action(id), let index = feed.rowIndex[id] {
                    actionRow(action, mark: mark(rows: feed.currentRows, index: index, hidden: feed.hidden),
                              branches: undo.log.branches(from: id))
                }
            }
        } header: {
            Text(HistoryDayTitle.title(for: day.start))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("history-day")
        }
    }

    /// A row of the list: the action on its rail, pushing its detail.
    private func actionRow(_ action: HistoryAction, mark: RailMark, branches: [HistoryLine]) -> some View {
        let id = action.actionID
        return NavigationLink(value: HistoryRoute.detail(id)) {
            HistoryRow(action: action, mark: mark, emphasized: true, branches: branches.map { undo.log.title(of: $0) },
                       blocked: undo.log.blocked[id], showsDate: false) { index in open(branches[index]) }
        }
        .id(id)
        .contextMenu { HistoryActionMenu(action: action, undo: undo) }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
        .accessibilityIdentifier("history-row-\(id.uuidString)")
    }

    /// Branches that split from before the first action: nothing wears
    /// their tag, so they are listed once, under the oldest day.
    private func rootsSection(_ lines: [HistoryLine]) -> some View {
        Section {
            ForEach(lines) { line in
                Button {
                    open(line)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(undo.log.title(of: line))
                                .font(.body.weight(.medium))
                            Text(line.actions.count == 1 ? "1 action · splits from the start" : "\(line.actions.count) actions · splits from the start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-root-branch-\(line.id.uuidString)")
            }
        } header: {
            Text(lines.count == 1 ? "Branch" : "Branches")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    // MARK: Search

    /// Every action, on any branch, that the ledger says touched what was
    /// typed — or whose title or place says it — by day, newest first.
    private var results: some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let current = found.needle == needle
        return List {
            ForEach(current ? found.days : [], id: \.start) { day in
                Section(HistoryDayTitle.title(for: day.start)) {
                    ForEach(day.actions, id: \.self) { id in
                        if let action = undo.log.action(id) {
                            NavigationLink(value: HistoryRoute.detail(action.actionID)) {
                                let dot: RailDot = action.actionID == undo.log.timeline.head ? .head : (action.isApplied ? .applied : .undone)
                                HistoryRow(action: action, mark: RailMark(above: nil, below: nil, dot: dot), emphasized: true,
                                           blocked: undo.log.blocked[action.actionID], showsDate: false)
                            }
                            .contextMenu { HistoryActionMenu(action: action, undo: undo) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                            .accessibilityIdentifier("history-result-\(action.actionID.uuidString)")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            // Nothing said until the answer for this text is in.
            if current, found.days.isEmpty { ContentUnavailableView.search(text: needle) }
        }
    }

    /// Floats over the list while a replay runs, so nothing shifts.
    private var busyPill: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Working…")
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: Capsule())
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-busy")
    }

    /// The foot of a cut list: how much older history there is, and the
    /// button that draws more of it.
    private func earlierRow(hidden: Int) -> some View {
        Button {
            withAnimation { shownLimit += HistoryLog.pageSize }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Color.clear.frame(width: 20, height: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show Earlier")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tint)
                    Text(hidden == 1 ? "1 earlier action" : "\(hidden.formatted()) earlier actions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.vertical, 10)
            .background(alignment: .leading) {
                HistoryRail(mark: RailMark(above: .solid, below: nil, dot: .more), emphasized: true)
                    .frame(width: 20)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
        .accessibilityIdentifier("history-show-earlier")
        // Scrolling to the foot draws the next page on its own; the row
        // stays a button for a tap that gets there first. Not animated: a
        // page arriving under a scroll should land, not slide.
        .onAppear {
            guard hidden > 0 else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { shownLimit += HistoryLog.pageSize }
        }
    }

    private func mark(rows: [UUID], index: Int, hidden: Int) -> RailMark {
        let timeline = undo.log.timeline
        let id = rows[index]
        func stroke(newer: UUID) -> RailStroke {
            timeline.state(of: newer) == .undone ? .dashed : .solid
        }
        let above: RailStroke? = index == 0 ? nil : stroke(newer: rows[index - 1])
        // On into the next row, or the Show Earlier row.
        let below: RailStroke? = index < rows.count - 1 || hidden > 0 ? stroke(newer: id) : nil
        let dot: RailDot = id == timeline.head ? .head : (timeline.state(of: id) == .applied ? .applied : .undone)
        return RailMark(above: above, below: below, dot: dot)
    }

    private func branchLength(_ option: HistoryAction) -> String {
        let length = undo.log.branchLength(from: option.actionID)
        return length == 1 ? "1 action" : "\(length) actions"
    }

    // MARK: Toolbar

    /// Undo and Redo together at the trailing end: one glass group, the
    /// way every editor puts them, each disabled when it has nothing to do.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // How undo, redo and branches work; information only.
        ToolbarItem(placement: .topBarLeading) {
            Button("About History", systemImage: "info.circle") { showGuide = true }
                .accessibilityIdentifier("history-info")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Task { await undo.undo() }
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!undo.canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .help(undo.undoTitle ?? "Undo")
            .accessibilityLabel(undo.undoTitle ?? "Undo")
            .accessibilityIdentifier("history-undo")

            redoItem
        }
    }

    /// Redo: a button, except at a fork, where a tap opens a menu of the
    /// branches (Mail's reply arrow: one control, several outcomes, a menu
    /// on tap) rather than guessing. No long press, no sheet.
    @ViewBuilder private var redoItem: some View {
        if undo.log.timeline.isFork {
            Menu {
                Section("Redo which branch?") {
                    ForEach(undo.log.redoOptions) { option in
                        Button {
                            Task { await undo.redo(branch: option.actionID) }
                        } label: {
                            Text(option.title)
                            Text(undo.log.blocked[option.actionID] ?? branchLength(option))
                            Image(systemName: "arrow.triangle.branch")
                        }
                        .disabled(undo.log.blocked[option.actionID] != nil)
                    }
                }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!undo.canRedo)
            .help("Redo…")
            .accessibilityLabel("Redo, choose a branch")
            .accessibilityIdentifier("history-redo")
        } else {
            Button {
                Task { await undo.redo() }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!undo.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .help(undo.redoTitle ?? "Redo")
            .accessibilityLabel(undo.redoTitle ?? "Redo")
            .accessibilityIdentifier("history-redo")
        }
    }
}

/// A row's context menu, here and on a branch's page. Jumps: several
/// steps at once, back through an applied action, forward through an
/// undone one below the head, or across to another branch — undoing to
/// the fork and redoing down the other side.
struct HistoryActionMenu: View {
    let action: HistoryAction
    let undo: UndoController

    var body: some View {
        switch action.state {
        case .applied:
            let steps = undo.log.timeline.undoPath(through: action.actionID).count
            Button {
                Task { await undo.undo(through: action.actionID) }
            } label: {
                Label(steps == 1 ? "Undo \(action.title)" : "Undo Through Here", systemImage: "arrow.uturn.backward")
                if steps > 1 { Text("\(steps) actions") }
            }
            .disabled(undo.isBusy)
        case .undone:
            let path = undo.log.timeline.jumpPath(to: action.actionID)
            if path.undos.isEmpty {
                Button {
                    Task { await undo.redo(through: action.actionID) }
                } label: {
                    Label(path.redos.count == 1 ? "Redo \(action.title)" : "Redo Through Here", systemImage: "arrow.uturn.forward")
                    if path.redos.count > 1 { Text("\(path.redos.count) actions") }
                }
                .disabled(undo.isBusy)
            } else {
                Button {
                    Task { await undo.jump(to: action.actionID) }
                } label: {
                    Label("Switch to This Branch", systemImage: "arrow.triangle.branch")
                    Text("\(path.undos.count) back, \(path.redos.count) forward")
                }
                .disabled(undo.isBusy)
            }
        }
    }
}

/// History's search answer for one text: the actions found, by day, newest
/// first. Built off the main actor; the view holds ids, not actions.
nonisolated struct HistorySearchResults: Sendable {
    struct Day: Sendable {
        let start: Date
        let actions: [UUID]
    }

    var needle: String?
    var days: [Day] = []

    init() {}

    init(needle: String, actions: [HistoryAction], matches: Set<UUID>, calendar: Calendar = .current) {
        self.needle = needle
        let found = actions.filter { action in
            matches.contains(action.actionID) || action.title.localizedStandardContains(needle)
                || action.detail.localizedStandardContains(needle)
        }
        let byDay = Dictionary(grouping: found) { calendar.startOfDay(for: $0.timestamp) }
        days = byDay.keys.sorted(by: >).map { Day(start: $0, actions: (byDay[$0] ?? []).map(\.actionID)) }
    }
}

/// One action on the rail: title, what and where, when; the copies at the
/// trailing end. The rail's dot is the state — filled, hollow, ringed —
/// so the row carries no second icon for it. Dimmed when undone; on the
/// current line an undone row is also marked, since it is what Redo
/// would take.
struct HistoryRow: View {
    let action: HistoryAction
    let mark: RailMark
    let emphasized: Bool
    /// Names of the branches that split off right after this action.
    var branches: [String] = []
    /// Why it can't be undone or redone from here, when it can't.
    var blocked: String? = nil
    /// Under a day's header the time alone; on a branch's page, which
    /// runs across days, the date too.
    var showsDate = true
    var onBranchTap: (Int) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 20, height: 1)

            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.body.weight(.medium))
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // One element for the text; the branch tags stay their own,
                // so a tag is a button to VoiceOver and the tests, not
                // folded into the row.
                .accessibilityElement(children: .combine)
                .accessibilityValue(action.isApplied ? "" : "Undone")

                // Next in line for Undo or Redo, and it can't run: said
                // here, before the button is tried.
                if let blocked {
                    Label(blocked, systemImage: "lock.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                        .accessibilityIdentifier("history-blocked")
                }

                // Where a branch leaves: one tag per branch, opening its
                // page. The only sign of the tree in the feed.
                if !branches.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(branches.prefix(2).enumerated()), id: \.offset) { index, name in
                            Button {
                                onBranchTap(index)
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.triangle.branch")
                                    Text(name)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Branch \(name)")
                            .accessibilityIdentifier("history-branch-tag")
                        }
                        if branches.count > 2 {
                            Text("+\(branches.count - 2) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 3)
                }
            }

            Spacer(minLength: 8)

            // Its own width, always: squeezed, "+98" wrapped a digit per
            // line under a long detail line. The text truncates instead.
            // The time sits under the count, where the eye already is.
            VStack(alignment: .trailing, spacing: 2) {
                if action.action == .deckBuild || action.action == .deckDisassemble {
                    // Copies moved, not added or removed.
                    Text("\(max(action.added, action.removed))")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(action.isApplied ? .primary : .secondary)
                    Text("moved")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if action.isListOnly {
                    // On a list: wanted, not owned — not the green of
                    // copies gained, and it says so.
                    Text(action.added > 0 ? "+\(action.added)" : "−\(action.removed)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(action.isApplied ? .primary : .secondary)
                    Text("on list")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    if action.added > 0 {
                        Text("+\(action.added)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(action.isApplied ? .green : .secondary)
                    }
                    if action.removed > 0 {
                        Text("−\(action.removed)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(action.isApplied ? .red : .secondary)
                    }
                }
                Text(action.timestamp, format: showsDate ? .dateTime.day().month().hour().minute() : .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if !action.isApplied, emphasized {
                    Text("Undone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityIdentifier("history-undone")
                }
            }
            .monospacedDigit()
            .fixedSize()
        }
        .padding(.vertical, 12)
        .background(alignment: .leading) {
            HistoryRail(mark: mark, emphasized: emphasized)
                .frame(width: 20)
        }
        .opacity(action.isApplied ? 1 : 0.6)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self, HistoryBranchName.self], inMemory: true)
}
