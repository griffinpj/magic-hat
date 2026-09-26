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
//  both ways forward are offered — as a section at the top of the list,
//  one row per branch with its name, length and age (a pending choice
//  lives in the content, the way Photos surfaces duplicates to review),
//  and from the Redo button as an action sheet (Mail's reply button: one
//  button whose action is ambiguous asks). No hidden gesture. Any row
//  pushes its detail — the cards it changed, and the one button that
//  undoes, redoes or switches to it — and its context menu does the same
//  in place. The ledger's own `.undo` / `.redo` actions are not rows —
//  they are what moves the marks.
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
    @State private var showsBranches = false

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
            .confirmationDialog("Redo Which Branch?", isPresented: $showsBranches, titleVisibility: .visible) {
                ForEach(undo.log.redoOptions) { option in
                    Button(branchLabel(option)) {
                        Task { await undo.redo(branch: option.actionID) }
                    }
                }
            } message: {
                Text("Your history splits here. The branch you don't take stays, and you can come back to it.")
            }
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
            if undo.log.timeline.isFork {
                forkSection
            }
            ForEach(undo.log.actions) { action in
                NavigationLink(value: action.actionID) {
                    HistoryRow(action: action, isBranchStart: undo.log.timeline.isFork && undo.log.timeline.redoOptions.contains(action.actionID))
                }
                .contextMenu { menu(for: action) }
                .accessibilityIdentifier("history-row-\(action.actionID.uuidString)")
            }
        }
        .animation(.default, value: undo.log.actions)
    }

    /// At a fork: the ways forward, one row each, the branch taken most
    /// recently first. Tapping a row redoes that branch.
    private var forkSection: some View {
        Section {
            ForEach(undo.log.redoOptions) { option in
                Button {
                    Task { await undo.redo(branch: option.actionID) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(option.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text("\(lengthText(option)) · \(option.timestamp, format: .relative(presentation: .named))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text("Redo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(undo.isBusy)
                .accessibilityIdentifier("history-branch-\(option.actionID.uuidString)")
            }
        } header: {
            Text("Your History Splits Here")
        } footer: {
            Text("Redo either branch. The other stays, and you can come back to it any time.")
        }
    }

    private func lengthText(_ option: HistoryAction) -> String {
        let length = undo.log.branchLength(from: option.actionID)
        return length == 1 ? "1 action" : "\(length) actions"
    }

    private func branchLabel(_ option: HistoryAction) -> String {
        "\(option.title) (\(lengthText(option)))"
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

    /// Redo: at a fork it asks which branch (an action sheet) rather than
    /// guessing; otherwise it redoes.
    private var redoItem: some View {
        Button {
            if undo.log.timeline.isFork {
                showsBranches = true
            } else {
                Task { await undo.redo() }
            }
        } label: {
            Label("Redo", systemImage: "arrow.uturn.forward")
        }
        .disabled(!undo.canRedo)
        .keyboardShortcut("z", modifiers: [.command, .shift])
        .help(undo.log.timeline.isFork ? "Redo…" : (undo.redoTitle ?? "Redo"))
        .accessibilityLabel(undo.log.timeline.isFork ? "Redo, choose a branch" : (undo.redoTitle ?? "Redo"))
        .accessibilityIdentifier("history-redo")
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
        case .manualAdd: return "plus.circle"
        case .manualRemove: return "minus.circle"
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
                Text(action.detail)
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
