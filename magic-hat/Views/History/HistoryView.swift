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
//  Undone actions stay listed, dimmed and marked, so the timeline reads:
//  the ones that can be redone, and the ones a later action left behind
//  (see HistoryTimeline). The ledger's own `.undo` / `.redo` actions are
//  not rows — they are what moves the marks.
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
                HistoryRow(action: action)
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

    /// Jumps: several steps back to (or forward to) this action at once.
    @ViewBuilder private func menu(for action: HistoryAction) -> some View {
        switch action.state {
        case .applied:
            let steps = undo.log.timeline.undoPath(through: action.actionID).count
            Button(steps == 1 ? "Undo \(action.title)" : "Undo to Here (\(steps) Actions)", systemImage: "arrow.uturn.backward") {
                Task { await undo.undo(through: action.actionID) }
            }
            .disabled(undo.isBusy)
        case .undone:
            let steps = undo.log.timeline.redoPath(through: action.actionID).count
            Button(steps == 1 ? "Redo \(action.title)" : "Redo to Here (\(steps) Actions)", systemImage: "arrow.uturn.forward") {
                Task { await undo.redo(through: action.actionID) }
            }
            .disabled(undo.isBusy)
        case .superseded:
            Text("Undone, then the timeline moved on")
        }
    }
}

private struct HistoryRow: View {
    let action: HistoryAction

    private var icon: String {
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
