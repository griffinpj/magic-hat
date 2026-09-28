//
//  CardSelection.swift
//  magic-hat
//
//  Choosing several cards at once, the same way on every screen that
//  shows cards — a collection or list, All Collection, search results, a
//  set, a deck's list. Photos' pattern: a long press on a card (or Select
//  Cards in the screen's "…" menu) starts it with that card chosen; taps
//  then toggle; the navigation bar becomes Select All · n Selected · Done;
//  the tab bar steps aside for one bottom bar of actions.
//
//  The bar is the same everywhere: Add (to any collection, list or deck
//  board), Buy (TCGplayer, Card Kingdom), then whatever the screen adds for
//  its own rows (a collection's Move and Remove, a deck's Move to board and
//  Remove). A screen owns a `CardSelection`, hands it to its grid or rows,
//  applies `cardSelectionBar`, and hides its own toolbar items while the
//  selection is active.
//

import SwiftUI
import SwiftData

@MainActor
@Observable
final class CardSelection {
    private(set) var isActive = false
    private(set) var ids: Set<String> = []
    /// Bumped after an action, for the haptic.
    private(set) var completed = 0
    /// "Added 5 cards to Wants", shown briefly after an Add.
    var toast: String?

    var count: Int { ids.count }

    func begin(with id: String? = nil) {
        isActive = true
        ids = id.map { [$0] } ?? []
    }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func selectAll(_ all: [String]) { ids = Set(all) }
    func deselectAll() { ids = [] }

    func end() {
        isActive = false
        ids = []
    }

    /// Drops ids no longer shown (a removed or moved card).
    func keep(only shown: some Sequence<String>) {
        guard isActive else { return }
        ids.formIntersection(shown)
    }

    func finished(_ message: String?) {
        completed += 1
        toast = message
        end()
        // The toast is seen; VoiceOver hears it.
        if let message { AccessibilityNotification.Announcement(message).post() }
    }
}

/// A screen's own action in the selection bar, beside Add and Buy.
struct SelectionAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    /// A menu of choices instead of one action (Move to…).
    var choices: [Choice] = []
    var perform: ([CardItem]) -> Void = { _ in }
    /// Whether the action is offered at all (a locked deck's aren't).
    /// Not per card: the chosen cards are only gathered when it runs.
    var isEnabled: () -> Bool = { true }

    struct Choice: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let section: String
        let perform: ([CardItem]) -> Void
    }
}

extension View {
    /// The selection's bars: Select All · n Selected · Done on top, and
    /// Add · Buy · the screen's own actions at the bottom, while `selection`
    /// is active. `items` is every card the screen shows, in order.
    /// `managesBack: false` for a screen that hides Back for its own
    /// reasons too (the deck screen, while searching) and folds the
    /// selection into that rule: an explicit "shown" here would override it.
    func cardSelectionBar(_ selection: CardSelection, items: [CardItem], actions: [SelectionAction] = [],
                          managesBack: Bool = true) -> some View {
        modifier(CardSelectionBar(selection: selection, items: items, actions: actions, managesBack: managesBack))
    }
}

private struct CardSelectionBar: ViewModifier {
    let selection: CardSelection
    let items: [CardItem]
    let actions: [SelectionAction]
    let managesBack: Bool

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query(sort: \MTGCollection.name) private var collections: [MTGCollection]
    @Query(sort: \Deck.name) private var decks: [Deck]
    @State private var error: String?
    /// Copies per card id, built when selecting starts, so the count in the
    /// bar is dictionary lookups rather than copying every chosen card on
    /// each redraw (0.2s with 3,800 chosen).
    @State private var copiesByID: [String: Int] = [:]
    @State private var buying = false
    /// A bulk add is running on the writer.
    @State private var working = false

    private var chosen: [CardItem] { items.filter { selection.contains($0.id) } }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if selection.isActive { bars }
            }
            .toolbar(selection.isActive ? .hidden : .automatic, for: .tabBar)
            .modifier(BackHidden(active: managesBack && selection.isActive, applies: managesBack))
            .animation(.default, value: selection.isActive)
            .sensoryFeedback(.success, trigger: selection.completed)
            .overlay(alignment: .top) {
                if let toast = selection.toast {
                    Label {
                        Text(toast)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(2))
                        selection.toast = nil
                    }
                    .accessibilityIdentifier("selection-toast")
                }
            }
            .animation(.snappy, value: selection.toast)
            .overlay {
                if working {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .task(id: selection.isActive) {
                guard selection.isActive else { copiesByID = [:]; return }
                let items = self.items
                copiesByID = await Task.detached(priority: .userInitiated) {
                    Dictionary(items.map { ($0.id, max($0.quantity, 1)) }, uniquingKeysWith: { a, _ in a })
                }.value
            }
            .confirmationDialog(buyTitle, isPresented: $buying, titleVisibility: .visible) {
                ForEach(CardStore.allCases) { store in
                    Button(store.label) {
                        let lines = CardStore.lines(chosen.map { ($0.name, max($0.quantity, 1)) })
                        if let url = store.url(for: lines) { openURL(url) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn't Add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
    }

    @ToolbarContentBuilder private var bars: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            let all = !items.isEmpty && selection.count == items.count
            Button(all ? "Deselect All" : "Select All") {
                if all { selection.deselectAll() } else { selection.selectAll(items.map(\.id)) }
            }
            .accessibilityIdentifier("selection-all")
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") { selection.end() }
                .accessibilityIdentifier("selection-done")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            addMenu
            // A button and a dialog, not a menu of links: a menu's items are
            // built on every redraw, and the links need every chosen card.
            Button("Buy", systemImage: "cart") { buying = true }
                .disabled(selection.count == 0)
                .accessibilityIdentifier("selection-buy")
            ForEach(actions.filter { $0.role != .destructive }) { actionItem($0) }
        }
        // The count in the middle of the bottom bar, as Photos has it: the
        // navigation bar's middle is taken by a large title on some screens.
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize()
                .accessibilityIdentifier("selection-count")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItemGroup(placement: .bottomBar) {
            ForEach(actions.filter { $0.role == .destructive }) { actionItem($0) }
        }
    }

    private var copies: Int {
        selection.ids.reduce(0) { $0 + (copiesByID[$1] ?? 1) }
    }

    private var buyTitle: String {
        copies == 1 ? "Buy 1 Card At" : "Buy \(copies) Cards At"
    }

    private var title: String {
        guard selection.count > 0 else { return "Select Cards" }
        let copies = self.copies
        return selection.count == copies ? "\(copies) Selected" : "\(selection.count) Selected (\(copies))"
    }

    @ViewBuilder private func actionItem(_ action: SelectionAction) -> some View {
        let enabled = selection.count > 0 && action.isEnabled()
        if action.choices.isEmpty {
            Button(action.title, systemImage: action.systemImage, role: action.role) { action.perform(chosen) }
                .disabled(!enabled)
                .accessibilityIdentifier("selection-\(action.id)")
        } else {
            Menu {
                let sections = action.choices.map(\.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                ForEach(sections, id: \.self) { section in
                    Section(section) {
                        ForEach(action.choices.filter { $0.section == section }) { choice in
                            Button(choice.title, systemImage: choice.systemImage) { choice.perform(chosen) }
                        }
                    }
                }
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
            .disabled(!enabled)
            .accessibilityIdentifier("selection-\(action.id)")
        }
    }

    /// Add copies of the chosen cards to any collection, list or deck.
    private var addMenu: some View {
        Menu {
            let owned = collections.filter { $0.kind == .collection }
            let lists = collections.filter { $0.kind == .list }
            if !owned.isEmpty {
                Section("Collections") {
                    ForEach(owned) { c in
                        Button(c.name, systemImage: CollectionKind.collection.systemImage) { add(to: c.name) }
                    }
                }
            }
            if !lists.isEmpty {
                Section("Lists") {
                    ForEach(lists) { c in
                        Button(c.name, systemImage: CollectionKind.list.systemImage) { add(to: c.name) }
                    }
                }
            }
            if !decks.isEmpty {
                Section("Decks") {
                    ForEach(decks.filter { !$0.isLocked }) { deck in
                        Menu(deck.name, systemImage: "rectangle.stack") {
                            ForEach(DeckBoard.addable, id: \.rawValue) { board in
                                Button(board.label) { add(to: deck.id, name: deck.name, board: board) }
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuOrder(.fixed)
        .disabled(selection.count == 0)
        .accessibilityIdentifier("selection-add")
    }

    /// A row brings its count (an owned row's copies, a deck row's); a
    /// search hit or printing is one copy.
    private static func copies(of item: CardItem) -> Int { max(item.quantity, 1) }

    private func add(to collection: String) {
        let cards = chosen
        let requests = cards.map { item in
            CollectionEditController.AddRequest(
                printing: PrintingSelection(item: item), collectionName: collection, quantity: Self.copies(of: item),
                finish: item.finish,
                condition: CardCondition(rawValue: item.condition)?.rawValue ?? CardCondition.nearMint.rawValue,
                language: item.isEntry && !item.language.isEmpty ? item.language : AppSettings.cardLanguage,
                purchasePrice: item.marketPrice
            )
        }
        let total = requests.reduce(0) { $0 + $1.quantity }
        working = true
        Task {
            defer { working = false }
            do {
                try await CollectionEditController.addMany(requests, context: modelContext)
                selection.finished("Added \(total == 1 ? "1 card" : "\(total) cards") to \(collection)")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func add(to deckID: UUID, name: String, board: DeckBoard) {
        let lines = chosen.map { DeckEditController.AddLine(printing: PrintingSelection(item: $0), quantity: Self.copies(of: $0)) }
        working = true
        Task {
            defer { working = false }
            do {
                let total = try await DeckEditController.addMany(lines, to: deckID, board: board, context: modelContext)
                selection.finished("Added \(total == 1 ? "1 card" : "\(total) cards") to \(name)")
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Hides Back while selecting — or, when the screen manages Back itself,
/// leaves the modifier out entirely.
private struct BackHidden: ViewModifier {
    let active: Bool
    let applies: Bool

    func body(content: Content) -> some View {
        if applies { content.navigationBarBackButtonHidden(active) } else { content }
    }
}

/// The ring on a card while choosing, filled once it is chosen — the
/// Photos mark. Shared by the grid's tiles and the deck's rows.
struct SelectionMark: View {
    let isSelected: Bool
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.black.opacity(0.25)))
            Circle()
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.9), lineWidth: 1.5)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.46, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
