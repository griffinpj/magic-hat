//
//  HistoryDetailView.swift
//  magic-hat
//
//  One action from the History tab, pushed from its row: what it did,
//  when, whether it stands, and the cards it changed — grouped by the
//  collection they went into or came out of, or for a deck build by the
//  move itself, one row per card with its art, printing and count. The
//  largest changes come first and each group shows at most
//  `HistoryDetail.visibleLimit` rows: an import is thousands, and the rest
//  is a search away (the field appears only when there is more than fits).
//
//  The one action for this row sits in a bottom bar as a prominent button
//  (Photos' Recover in Recently Deleted): Undo, Redo, through here when
//  several steps are needed, or Switch to This Branch when it lies down
//  the other side of a fork. It reads the live log, so it flips as soon
//  as the replay lands.
//

import SwiftUI
import SwiftData

struct HistoryDetailView: View {
    let actionID: UUID

    @Environment(\.modelContext) private var modelContext
    private var undo: UndoController { .shared(for: modelContext.container) }
    @State private var model = HistoryDetailModel()
    @State private var searchText = ""

    private var action: HistoryAction? { undo.log.action(actionID) }

    var body: some View {
        List {
            if let action { header(action) }
            if let shown = model.shown {
                ForEach(shown.groups) { group in
                    groupSection(group)
                }
                if shown.groups.isEmpty, !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading the ledger…").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(action?.title ?? "Action")
        .navigationBarTitleDisplayMode(.inline)
        .modifier(SearchWhenLong(isLong: (model.detail?.changeCount ?? 0) > HistoryDetail.visibleLimit, text: $searchText))
        .onChange(of: searchText) { _, text in model.filter(text) }
        .task(id: actionID) { await model.load(actionID, store: .shared(for: modelContext.container)) }
        .safeAreaBar(edge: .bottom) { if let action { actionBar(action) } }
    }

    // MARK: Header

    @ViewBuilder private func header(_ action: HistoryAction) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon(for: action))
                        .font(.title2)
                        .foregroundStyle(action.isApplied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.title).font(.title3.weight(.semibold))
                        Text(action.detail).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Text(action.timestamp, format: .dateTime.weekday(.wide).day().month().year().hour().minute())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(action.isApplied ? "Applied" : "Undone")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(action.isApplied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(action.isApplied ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary), in: Capsule())
                        .accessibilityIdentifier("history-detail-state")
                }
                HStack(spacing: 16) {
                    if action.added > 0 {
                        Label(action.added == 1 ? "1 copy in" : "\(action.added.formatted()) copies in", systemImage: "plus")
                            .foregroundStyle(.green)
                    }
                    if action.removed > 0 {
                        Label(action.removed == 1 ? "1 copy out" : "\(action.removed.formatted()) copies out", systemImage: "minus")
                            .foregroundStyle(.red)
                    }
                    if let detail = model.detail {
                        Text(detail.changeCount == 1 ? "1 card" : "\(detail.changeCount.formatted()) cards")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.weight(.medium))
            }
            .padding(.vertical, 4)
        }
    }

    private func icon(for action: HistoryAction) -> String {
        switch action.action {
        case .deckBuild, .deckDisassemble: return "rectangle.stack"
        case .manualRemove: return "minus.circle"
        case .manualAdd: return "plus.circle"
        default: return "square.and.arrow.down"
        }
    }

    // MARK: Groups

    @ViewBuilder private func groupSection(_ group: HistoryChangeGroup) -> some View {
        Section {
            ForEach(group.changes) { change in
                HistoryChangeRow(change: change, isMove: group.kind == .move)
            }
        } header: {
            HStack(spacing: 6) {
                if group.kind == .move, let destination = group.destination {
                    Text(group.title)
                    Image(systemName: "arrow.right").font(.caption2.weight(.semibold))
                    Text(destination)
                } else {
                    Text(group.title)
                }
                Spacer()
                if group.kind == .move {
                    Text("\(group.added.formatted()) moved")
                } else {
                    if group.added > 0 { Text("+\(group.added.formatted())").foregroundStyle(.green) }
                    if group.removed > 0 { Text("−\(group.removed.formatted())").foregroundStyle(.red) }
                }
            }
            .textCase(nil)
        } footer: {
            if group.hidden > 0 {
                Text(group.hidden == 1 ? "1 more card. Search to find it." : "\(group.hidden.formatted()) more cards. Search to find one.")
            }
        }
    }

    // MARK: The action

    @ViewBuilder private func actionBar(_ action: HistoryAction) -> some View {
        let plan = plan(for: action)
        Button {
            Task { await plan.run() }
        } label: {
            VStack(spacing: 2) {
                Label(plan.title, systemImage: plan.symbol)
                    .font(.body.weight(.semibold))
                if let note = plan.note {
                    Text(note).font(.caption).opacity(0.85)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(undo.isBusy)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
        .accessibilityIdentifier("history-detail-action")
    }

    private struct ActionPlan {
        let title: String
        let note: String?
        let symbol: String
        let run: () async -> Void
    }

    private func plan(for action: HistoryAction) -> ActionPlan {
        let timeline = undo.log.timeline
        switch action.state {
        case .applied:
            let steps = timeline.undoPath(through: action.actionID).count
            return ActionPlan(
                title: steps <= 1 ? "Undo This Action" : "Undo Through Here",
                note: steps <= 1 ? nil : "\(steps) actions back",
                symbol: "arrow.uturn.backward"
            ) { await undo.undo(through: action.actionID) }
        case .undone:
            let path = timeline.jumpPath(to: action.actionID)
            if path.undos.isEmpty {
                return ActionPlan(
                    title: path.redos.count <= 1 ? "Redo This Action" : "Redo Through Here",
                    note: path.redos.count <= 1 ? nil : "\(path.redos.count) actions forward",
                    symbol: "arrow.uturn.forward"
                ) { await undo.redo(through: action.actionID) }
            }
            return ActionPlan(
                title: "Switch to This Branch",
                note: "\(path.undos.count) back, \(path.redos.count) forward",
                symbol: "arrow.triangle.branch"
            ) { await undo.jump(to: action.actionID) }
        }
    }
}

/// A search field only when a list is long enough to need one.
private struct SearchWhenLong: ViewModifier {
    let isLong: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if isLong {
            content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a card")
        } else {
            content
        }
    }
}

/// One changed printing: art, set symbol and name, the printing under it,
/// the copies at the trailing end — signed for a collection, plain for a
/// move.
private struct HistoryChangeRow: View {
    let change: HistoryChange
    let isMove: Bool

    var body: some View {
        HStack(spacing: 12) {
            CardArtThumb(artURL: change.artCropURL, fallbackURL: change.imageURL)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if !change.setCode.isEmpty {
                        SetSymbolView(setCode: change.setCode, size: 15, tint: .primary, rarity: change.rarity)
                    }
                    Text(change.name).lineLimit(1)
                }
                if !change.printingLine.isEmpty {
                    Text(change.printingLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(isMove ? "×\(change.delta)" : (change.delta > 0 ? "+\(change.delta)" : "−\(-change.delta)"))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isMove ? AnyShapeStyle(.secondary) : change.delta > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.red))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("history-change-\(change.scryfallID)")
    }
}

/// Holds the changes as a reference, not a value in the view: an import's
/// detail is thousands of rows, and a `@State` array is compared element
/// by element on every update of the parent.
@MainActor
@Observable
final class HistoryDetailModel {
    private(set) var detail: HistoryDetail?
    /// What the list draws: filtered by the search text, then capped.
    private(set) var shown: HistoryDetail?
    private var filterTask: Task<Void, Never>?

    func load(_ actionID: UUID, store: CollectionStore) async {
        guard detail?.actionID != actionID else { return }
        let loaded = try? await store.historyDetail(actionID: actionID)
        detail = loaded
        shown = loaded?.capped()
    }

    func filter(_ text: String) {
        filterTask?.cancel()
        guard let detail else { return }
        filterTask = Task.detached(priority: .userInitiated) {
            let result = detail.filtered(text).capped()
            guard !Task.isCancelled else { return }
            await MainActor.run { self.shown = result }
        }
    }
}
