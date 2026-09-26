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
//  The timeline is a tree (see HistoryTimeline) and the list shows it as
//  branches, git's idea without git's chrome: the current line first —
//  what is applied, and above it, dimmed, what Redo would take — then a
//  section per other branch, named by the user or for the action it
//  forks from, with a Switch button (checkout) and Rename in its context
//  menu. A rail in the gutter (HistoryRail) draws each branch as a line
//  with a dot per action, so a fork reads at a glance without a graph
//  mode; a lane graph over a mostly linear history is noise, and no
//  toggle means one list to keep right. At a fork the Redo button opens
//  a menu of the branches on tap (Mail's reply arrow: one control,
//  several outcomes, a menu on tap) — no hidden gesture, no sheet. Any row pushes
//  its detail: the cards it changed, and the one button that undoes,
//  redoes or switches to it.
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
    private var deckTracker: DeckChangeTracker { .shared }
    private var undo: UndoController { .shared(for: modelContext.container) }
    @State private var renaming: HistoryLine?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
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
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { HistoryDetailView(actionID: $0) }
            .toolbar { toolbar }
            .task(id: "\(tracker.revision)|\(deckTracker.revision)") { await undo.refresh() }
            .sensoryFeedback(.success, trigger: undo.completed)
            .alert("Couldn't Change That", isPresented: Binding(get: { undo.error != nil }, set: { if !$0 { undo.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(undo.error ?? "")
            }
        }
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            List {
                if let line = undo.log.currentLine {
                    lineSection(line, proxy: proxy)
                }
                ForEach(undo.log.otherLines) { line in
                    lineSection(line, proxy: proxy)
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.default, value: undo.log.actions)
        .overlay(alignment: .bottom) {
            if undo.isBusy { busyPill }
        }
        .animation(.default, value: undo.isBusy)
        .alert("Rename Branch", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { line in
            TextField("Name", text: $renameText)
            Button("Save") {
                let name = renameText
                Task { await undo.rename(line, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to use the default name.")
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

    /// One branch: its actions newest first on a rail, under a header
    /// that names it and, for another branch, offers Switch; a row that a
    /// branch leaves from carries a tag naming it (tap: the branch's
    /// card), and another branch's card ends in a junction row saying
    /// which action it splits from (tap: that row) and what Switch does.
    @ViewBuilder private func lineSection(_ line: HistoryLine, proxy: ScrollViewProxy) -> some View {
        let rows = Array(line.actions.reversed())
        Section {
            ForEach(Array(rows.enumerated()), id: \.element) { index, id in
                if let action = undo.log.action(id) {
                    let branches = undo.log.branches(from: id)
                    NavigationLink(value: id) {
                        HistoryRow(action: action, mark: mark(for: line, rows: rows, index: index, stub: !branches.isEmpty),
                                   emphasized: line.isCurrent, branches: branches.map { undo.log.title(of: $0) }) { branchIndex in
                            withAnimation { proxy.scrollTo("line-\(branches[branchIndex].id.uuidString)", anchor: .top) }
                        }
                    }
                    .id(id)
                    .contextMenu { menu(for: action) }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                    .accessibilityIdentifier("history-row-\(id.uuidString)")
                }
            }
            if !line.isCurrent {
                let cost = undo.log.switchCost(of: line)
                Button {
                    withAnimation {
                        if let fork = line.forkFrom {
                            proxy.scrollTo(fork, anchor: .center)
                        } else if let start = undo.log.currentLine?.actions.first {
                            proxy.scrollTo(start, anchor: .bottom)
                        }
                    }
                } label: {
                    HistoryJunctionRow(origin: junctionText(for: line), cost: cost)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                .accessibilityIdentifier("history-junction-\(line.id.uuidString)")
            }
        } header: {
            lineHeader(line)
                .id("line-\(line.id.uuidString)")
        }
    }

    /// "Splits from Added Sol Ring in Timeline", or "Splits from the start".
    private func junctionText(for line: HistoryLine) -> String {
        guard let fork = undo.log.action(line.forkFrom) else { return "Splits from the start" }
        if let host = undo.log.line(containing: fork.actionID) {
            return "Splits from \(fork.title) in \(undo.log.title(of: host))"
        }
        return "Splits from \(fork.title)"
    }

    private func mark(for line: HistoryLine, rows: [UUID], index: Int, stub: Bool) -> RailMark {
        let timeline = undo.log.timeline
        let id = rows[index]
        func stroke(newer: UUID) -> RailStroke {
            line.isCurrent && timeline.state(of: newer) == .undone ? .dashed : .solid
        }
        let above: RailStroke? = index == 0 ? nil : stroke(newer: rows[index - 1])
        let below: RailStroke?
        if index < rows.count - 1 {
            below = stroke(newer: id)
        } else {
            below = line.isCurrent ? nil : .solid   // on into the junction row
        }
        let dot: RailDot = id == timeline.head ? .head : (timeline.state(of: id) == .applied ? .applied : .undone)
        return RailMark(above: above, below: below, dot: dot, stub: stub)
    }

    @ViewBuilder private func lineHeader(_ line: HistoryLine) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(undo.log.title(of: line))
                    .font(.headline)
                    .foregroundStyle(.primary)
                lineCaption(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !line.isCurrent {
                let cost = undo.log.switchCost(of: line)
                Button("Switch") {
                    Task { await undo.switchTo(line) }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .font(.subheadline.weight(.semibold))
                .disabled(undo.isBusy)
                .help("Undo \(cost.back) and redo \(cost.forward)")
                .accessibilityLabel("Switch to this branch: \(cost.back) back, \(cost.forward) forward")
                .accessibilityIdentifier("history-switch-\(line.id.uuidString)")
            }
            Menu {
                Button("Rename…", systemImage: "pencil") {
                    renameText = undo.log.customName(of: line) ?? ""
                    renaming = line
                }
                if !line.isCurrent {
                    Button("Switch to This Branch", systemImage: "arrow.triangle.branch") {
                        Task { await undo.switchTo(line) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Branch options")
            .accessibilityIdentifier("history-line-menu-\(line.id.uuidString)")
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    /// "3 applied · 2 to redo" for the current line; "2 actions · 5 minutes
    /// ago" for another.
    private func lineCaption(_ line: HistoryLine) -> Text {
        if line.isCurrent {
            let applied = undo.log.timeline.applied.count
            let ahead = line.actions.count - applied
            var parts: [String] = [applied == 1 ? "1 applied" : "\(applied) applied"]
            if ahead > 0 { parts.append(ahead == 1 ? "1 to redo" : "\(ahead) to redo") }
            return Text(parts.joined(separator: " · "))
        }
        let count = line.actions.count == 1 ? "1 action" : "\(line.actions.count) actions"
        if let latest = undo.log.latest(on: line) {
            return Text("\(count) · \(latest, format: .relative(presentation: .named))")
        }
        return Text(count)
    }

    private func branchLength(_ option: HistoryAction) -> String {
        let length = undo.log.branchLength(from: option.actionID)
        return length == 1 ? "1 action" : "\(length) actions"
    }

    // MARK: Toolbar

    /// Undo and Redo together at the trailing end: one glass group, the
    /// way every editor puts them, each disabled when it has nothing to do.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
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
                            Text(branchLength(option))
                            Image(systemName: "arrow.triangle.branch")
                        }
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

    /// Jumps: several steps at once, back through an applied action,
    /// forward through an undone one below the head, or across to another
    /// branch — undoing to the fork and redoing down the other side.
    @ViewBuilder private func menu(for action: HistoryAction) -> some View {
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

/// One action on the rail: icon, title, what and where, when; the copies
/// at the trailing end. Dimmed when undone; on the current line an
/// undone row is also marked, since it is what Redo would take.
private struct HistoryRow: View {
    let action: HistoryAction
    let mark: RailMark
    let emphasized: Bool
    /// Names of the branches that split off right after this action.
    var branches: [String] = []
    var onBranchTap: (Int) -> Void = { _ in }

    private var icon: String {
        switch action.action {
        case .deckBuild, .deckDisassemble: return "rectangle.stack"
        case .manualAdd: return "plus.circle"
        case .manualRemove: return "minus.circle"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        default: return "square.and.arrow.down"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Color.clear.frame(width: 20, height: 1)
            Image(systemName: icon)
                .foregroundStyle(action.isApplied ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.body.weight(.medium))
                    Text(action.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(action.timestamp, format: .dateTime.day().month().year().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // One element for the text; the branch tags stay their own,
                // so a tag is a button to VoiceOver and the tests, not
                // folded into the row.
                .accessibilityElement(children: .combine)
                .accessibilityValue(action.isApplied ? "" : "Undone")

                // Where a branch leaves: under the text, beside the stub
                // peeling off the rail, one tag per branch.
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
            .layoutPriority(1)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
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
        }
        .padding(.vertical, 12)
        .background(alignment: .leading) {
            HistoryRail(mark: mark, emphasized: emphasized)
                .frame(width: 20)
        }
        .opacity(action.isApplied ? 1 : 0.6)
    }
}

/// The foot of another branch's card: the rail runs into a small dot and
/// the text says which action the branch splits from and what Switch
/// would do. Tapping it scrolls to that action.
private struct HistoryJunctionRow: View {
    let origin: String
    let cost: (back: Int, forward: Int)

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Color.clear.frame(width: 20, height: 1)
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(origin)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Switch: \(cost.back) back, \(cost.forward) forward")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            HistoryRail(mark: RailMark(above: .solid, below: nil, dot: .junction), emphasized: false)
                .frame(width: 20)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self, HistoryBranchName.self], inMemory: true)
}
