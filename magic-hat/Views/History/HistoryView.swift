//
//  HistoryView.swift
//  magic-hat
//
//  The append-only audit ledger grouped by action, newest first — each
//  import, edit, build or disassembly as one row — and the way back: Undo
//  and Redo in the bar, as Notes and Freeform place them, each disabled
//  when there is nothing to do and named for what it would do ("Undo
//  Removed Cards"), with ⌘Z / ⇧⌘Z on a keyboard. Any number of steps in
//  either direction; a row's menu jumps several at once ("Undo to Here").
//
//  Undone actions stay listed, dimmed and marked. The timeline is a tree
//  (see HistoryTimeline): undo back to where a new action forked it and
//  Redo offers both ways forward — a tap takes the most recent branch, a
//  long press lists them — and any row's menu can jump straight to it,
//  undoing back to the fork and redoing down the other side. The ledger's
//  own `.undo` / `.redo` actions are not rows — they are what moves the
//  marks.
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

    private var list: some View {
        List {
            if undo.isBusy {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Working…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("history-busy")
            }
            ForEach(undo.log.actions) { action in
                HistoryRow(action: action, isBranchStart: undo.log.timeline.isFork && undo.log.timeline.redoOptions.contains(action.actionID))
                    .contextMenu { menu(for: action) }
                    .accessibilityIdentifier("history-row-\(action.actionID.uuidString)")
            }
        }
        .animation(.default, value: undo.log.actions)
    }

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

    /// Redo: a plain button, except at a fork, where a tap takes the most
    /// recently taken branch and a long press lists every branch — the
    /// shape of Safari's tabs button and Notes' Undo.
    @ViewBuilder private var redoItem: some View {
        if undo.log.timeline.isFork {
            Menu {
                ForEach(undo.log.redoOptions) { option in
                    Button {
                        Task { await undo.redo(branch: option.actionID) }
                    } label: {
                        Text("Redo \(option.title)")
                        let length = undo.log.branchLength(from: option.actionID)
                        Text(length == 1 ? "1 action on this branch" : "\(length) actions on this branch")
                    }
                    .accessibilityIdentifier("history-redo-branch-\(option.actionID.uuidString)")
                }
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            } primaryAction: {
                Task { await undo.redo() }
            }
            .disabled(!undo.canRedo)
            .help(undo.redoTitle ?? "Redo")
            .accessibilityLabel(undo.redoTitle ?? "Redo")
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

private struct HistoryRow: View {
    let action: HistoryAction
    /// One of the ways forward from the head, at a fork.
    var isBranchStart = false

    private var icon: String {
        if isBranchStart { return "arrow.triangle.branch" }
        switch action.action {
        case .deckBuild, .deckDisassemble: return "rectangle.stack"
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        default: return "square.and.arrow.down"
        }
    }

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon)
                .foregroundStyle(action.isApplied ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(action.title).font(.body.weight(.medium))
                Text(action.scopes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(action.timestamp, format: .dateTime.day().month().year().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

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
                if !action.isApplied {
                    Text(isBranchStart ? "Undone · branch" : "Undone")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .accessibilityIdentifier("history-undone")
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(action.isApplied ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(action.isApplied ? "" : "Undone")
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: [CollectionEntry.self, CardMeta.self, AuditRecord.self], inMemory: true)
}
