//
//  DeckCardsView.swift
//  magic-hat
//
//  The Cards tab of a deck: the list itself — commander, then the
//  mainboard grouped by type with counts and value, then sideboard and
//  maybeboard — with each row saying what the collection can do about it
//  (built, available, missing). The screen's search field narrows the
//  list — the text arrives from the parent, which owns the field. Adding
//  cards is the "+" in the bar: DeckAddCardsView, a sheet, so the field
//  has one meaning.
//
//  A plain list, so the type headers pin as the list scrolls (Contacts,
//  Music's Songs): a hundred rows in eight groups, and mid-scroll the
//  header says which group this is. The inset-grouped style never pins.
//  Rows have no swipe actions — the stepper takes a card out in one tap,
//  and a trailing swipe on a paged screen fought the page swipe.
//
//  When the deck breaks a rule of its format (over the size, outside the
//  commander's colour identity, over a copy limit, not legal) the first
//  row says so and leads to the Stats tab's full check. A banner row, not
//  an alert: the state is allowed and common mid-build, and it clears
//  itself as the list is fixed.
//

import SwiftUI
import SwiftData

struct DeckCardsView: View {
    let snapshot: DeckSnapshot
    /// The screen's search text, applied in memory.
    let filterText: String
    let onAddCards: () -> Void
    /// Tapping the issues row: the Stats tab lists every issue.
    var onShowIssues: (() -> Void)? = nil
    /// The deck's analysis, for the swaps row; nil when the list is not
    /// analysed (previews).
    var analysis: DeckAnalysisController? = nil
    /// Tapping the swaps row: the swap table.
    var onShowSwaps: (() -> Void)? = nil
    /// The zoom namespace and the viewer belong to the deck screen, which
    /// presents the viewer (see DeckDetailView): a `fullScreenCover` on
    /// this page stopped presenting after a sheet had been shown while
    /// another page was selected, until the page was re-selected.
    let zoom: Namespace.ID
    /// The viewer the screen is showing, so the list can follow it.
    var viewer: CardViewerSession? = nil
    /// The deck as the viewer's target: −/+ on the mainboard in its bar,
    /// and "+" on the Synergies screen it pushes. Nil while loading.
    var session: DeckAddSession? = nil
    var onOpenViewer: ((CardViewerSession) -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @State private var error: String?

    private var locked: Bool { snapshot.isLocked }
    private var trimmedFilter: String { filterText.trimmingCharacters(in: .whitespaces) }

    /// The rows matching the field, or nil when nothing is typed.
    private var filtered: [DeckCardItem]? {
        guard !trimmedFilter.isEmpty else { return nil }
        var q = CardSearchQuery()
        q.text = trimmedFilter
        return snapshot.allItems.filter { q.matches($0.card) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            content
                // Keep the viewer's row in view so the zoom-out lands on it.
                .onChange(of: viewer?.currentID) { old, id in
                    guard old != nil, let id else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(id) }
                }
        }
            .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    @ViewBuilder private var content: some View {
        if snapshot.allItems.isEmpty {
            ContentUnavailableView {
                Label("No Cards", systemImage: "rectangle.stack")
            } description: {
                Text(locked ? "Unlock the deck to add cards." : "Add cards from your collection or from all of Magic.")
            } actions: {
                if !locked {
                    Button("Add Cards", systemImage: "plus", action: onAddCards)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("deck-empty-add")
                }
            }
        } else if let filtered, filtered.isEmpty {
            ContentUnavailableView.search(text: trimmedFilter)
        } else {
            List {
                if let filtered {
                    Section {
                        ForEach(filtered) { row($0) }
                    } header: {
                        header { Text("\(filtered.count) matching") }
                    }
                } else {
                    if !snapshot.stats.violations.isEmpty {
                        issuesRow
                    }
                    if let plan = analysis?.plan, plan.changeCount > 0 {
                        swapsRow(plan)
                    }
                    if snapshot.format.hasCommander || !snapshot.commanders.isEmpty {
                        Section {
                            ForEach(snapshot.commanders) { row($0) }
                            if snapshot.commanders.isEmpty {
                                Text("No commander chosen").foregroundStyle(.secondary)
                            }
                        } header: {
                            header { Label("Commander", systemImage: "crown") }
                        }
                    }
                    ForEach(snapshot.sections) { section in
                        Section {
                            ForEach(section.items) { row($0) }
                        } header: {
                            header {
                                if let glyph = section.glyph {
                                    ManaGlyphView(name: glyph, size: 14)
                                }
                                Text(section.title)
                                Spacer()
                                Text("\(section.copies) · \(PriceFormat.compact(section.value))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !snapshot.sideboard.isEmpty {
                        Section {
                            ForEach(snapshot.sideboard) { row($0) }
                        } header: {
                            header { Text("Sideboard · \(snapshot.sideboard.reduce(0) { $0 + $1.quantity })") }
                        }
                    }
                    if !snapshot.maybeboard.isEmpty {
                        Section {
                            ForEach(snapshot.maybeboard) { row($0) }
                        } header: {
                            header { Text("Maybeboard · \(snapshot.maybeboard.reduce(0) { $0 + $1.quantity })") }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    /// A pinned header: sentence case and primary, as in Music, rather than
    /// the small caps of a grouped list.
    private func header<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var issuesRow: some View {
        Section {
            Button {
                onShowIssues?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(snapshot.stats.violationSummary)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Deck issues: \(snapshot.stats.violationSummary)")
            .accessibilityIdentifier("deck-issues")
        }
    }

    /// The swap table has something to say: a row, like the issues row,
    /// so it is never buried. Absent when there is nothing to suggest.
    private func swapsRow(_ plan: DeckPlan) -> some View {
        Section {
            Button {
                onShowSwaps?()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(Color.accentColor)
                    Text(Self.swapsLine(plan))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Suggested swaps: \(Self.swapsLine(plan))")
            .accessibilityIdentifier("deck-swaps-row")
        }
    }

    nonisolated static func swapsLine(_ plan: DeckPlan) -> String {
        var bits: [String] = []
        if !plan.swaps.isEmpty { bits.append(plan.swaps.count == 1 ? "1 swap" : "\(plan.swaps.count) swaps") }
        if !plan.fills.isEmpty { bits.append(plan.fills.count == 1 ? "1 add" : "\(plan.fills.count) adds") }
        if !plan.trims.isEmpty { bits.append(plan.trims.count == 1 ? "1 cut" : "\(plan.trims.count) cuts") }
        return "Suggested: " + bits.joined(separator: " · ")
    }

    private func row(_ item: DeckCardItem) -> some View {
        DeckCardRow(item: item, locked: locked, zoom: zoom, onSetQuantity: { setQuantity(item, $0) },
                    onOpen: { open(item) })
            .id(item.card.id)
            .contextMenu {
                if !locked {
                    ForEach(DeckBoard.addable.filter { $0 != item.board }, id: \.rawValue) { b in
                        Button("Move to \(b.label)", systemImage: "arrow.right") { move(item, to: b) }
                    }
                    if snapshot.format.hasCommander, item.board != .commander {
                        Button("Set as Commander", systemImage: "crown") { setCommander(item) }
                    }
                    Divider()
                    Button("Remove", systemImage: "trash", role: .destructive) { setQuantity(item, 0) }
                }
            }
    }

    // MARK: Actions

    private func setQuantity(_ item: DeckCardItem, _ quantity: Int) {
        do { try DeckEditController.setQuantity(deckCardID: item.id, quantity, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func move(_ item: DeckCardItem, to board: DeckBoard) {
        do { try DeckEditController.move(deckCardID: item.id, to: board, context: modelContext) }
        catch { self.error = error.localizedDescription }
    }

    private func setCommander(_ item: DeckCardItem) {
        do {
            try DeckEditController.setCommander(deckID: snapshot.id, PrintingSelection(item: item.card), context: modelContext)
            try DeckEditController.setQuantity(deckCardID: item.id, 0, context: modelContext)
        } catch { self.error = error.localizedDescription }
    }

    /// The viewer pages through the whole list (or the filtered rows).
    private func open(_ item: DeckCardItem) {
        let items = (filtered ?? snapshot.allItems).map(\.card)
        session?.board = .main
        onOpenViewer?(CardViewerSession(items: items, currentID: item.card.id, deck: locked ? nil : session))
    }
}
