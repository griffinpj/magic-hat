//
//  HistoryBranchView.swift
//  magic-hat
//
//  One branch of the history, pushed from the tag on the row it splits
//  from (or from the Branches section at the foot of the feed, for one
//  that splits from the start): its actions newest first on a secondary
//  rail, the footer saying what it splits from, and Switch — undo back to
//  the fork, redo along this branch — as the one prominent button in the
//  bottom bar with what it would do under it. Rename in the "…" menu. The
//  same shape as a deck version's page (DeckVersionCompareView), so the
//  app's two histories read alike. A branch off this branch wears its tag
//  here, on the row it leaves from, so every chain is reachable.
//
//  Once switched to, the branch *is* the timeline and this page has
//  nothing to show: HistoryView takes it off its path (a view can't pop
//  itself from under the detail pushed over it).
//

import SwiftUI
import SwiftData

/// What History's stack holds: an action's detail, or a branch's page.
nonisolated enum HistoryRoute: Hashable, Sendable {
    case detail(UUID)
    case branch(UUID)
}

struct HistoryBranchView: View {
    let lineID: UUID
    /// Pushes another branch (one off this one).
    let onOpenBranch: (HistoryLine) -> Void

    @Environment(\.modelContext) private var modelContext
    private var undo: UndoController { .shared(for: modelContext.container) }
    @State private var renaming = false
    @State private var renameText = ""

    private var line: HistoryLine? { undo.log.lines.first { $0.id == lineID && !$0.isCurrent } }

    var body: some View {
        Group {
            if let line {
                content(line)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(line.map { undo.log.title(of: $0) } ?? "Branch")
        .navigationSubtitle(line.map(caption) ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let line {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename…", systemImage: "pencil") {
                            renameText = undo.log.customName(of: line) ?? ""
                            renaming = true
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("history-branch-menu")
                }
            }
        }
        .safeAreaBar(edge: .bottom) {
            if let line { switchBar(line) }
        }
        .alert("Rename Branch", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                guard let line else { return }
                let name = renameText
                Task { await undo.rename(line, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave it empty to use the default name.")
        }
    }

    private func content(_ line: HistoryLine) -> some View {
        let rows = Array(line.actions.reversed())
        return List {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element) { index, id in
                    if let action = undo.log.action(id) {
                        let branches = undo.log.branches(from: id)
                        NavigationLink(value: HistoryRoute.detail(id)) {
                            HistoryRow(action: action,
                                       mark: RailMark(above: index == 0 ? nil : .solid,
                                                      below: index == rows.count - 1 ? nil : .solid, dot: .undone),
                                       emphasized: false, branches: branches.map { undo.log.title(of: $0) },
                                       showsDate: true) { tapped in onOpenBranch(branches[tapped]) }
                        }
                        .contextMenu { HistoryActionMenu(action: action, undo: undo) }
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + 36 }
                        .accessibilityIdentifier("history-row-\(id.uuidString)")
                    }
                }
            } footer: {
                Text(origin(of: line))
                    .accessibilityIdentifier("history-branch-origin")
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .bottom) {
            if undo.isBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: Capsule())
                .padding(.bottom, 12)
                .accessibilityIdentifier("history-busy")
            }
        }
        .animation(.default, value: undo.isBusy)
    }

    /// Switch: the one thing to do with a branch.
    private func switchBar(_ line: HistoryLine) -> some View {
        let cost = undo.log.switchCost(of: line)
        return VStack(spacing: 6) {
            Button {
                Task { await undo.switchTo(line) }
            } label: {
                Label("Switch to This Branch", systemImage: "arrow.triangle.branch")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(undo.isBusy)
            .accessibilityLabel("Switch to this branch: \(cost.back) back, \(cost.forward) forward")
            .accessibilityIdentifier("history-branch-switch")
            Text("\(cost.back == 1 ? "1 step" : "\(cost.back) steps") back, \(cost.forward == 1 ? "1 step" : "\(cost.forward) steps") forward")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("history-branch-cost")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// "3 actions · 5 minutes ago".
    private func caption(_ line: HistoryLine) -> String {
        let count = line.actions.count == 1 ? "1 action" : "\(line.actions.count) actions"
        guard let latest = undo.log.latest(on: line) else { return count }
        return "\(count) · \(latest.formatted(.relative(presentation: .named)))"
    }

    /// "Splits from Added Sol Ring", or "Splits from the start".
    private func origin(of line: HistoryLine) -> String {
        guard let fork = undo.log.action(line.forkFrom) else { return "Splits from the start" }
        if let host = undo.log.line(containing: fork.actionID), !host.isCurrent {
            return "Splits from \(fork.title) in \(undo.log.title(of: host))"
        }
        return "Splits from \(fork.title)"
    }
}
