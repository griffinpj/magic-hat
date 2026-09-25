//
//  CardSynergiesView.swift
//  magic-hat
//
//  The cards that work with this one, pushed from the viewer's Synergies
//  action inside the viewer's own NavigationStack (like Details): combos
//  it is part of, the cards played with it, and the cards that share its
//  theme — three sections, each saying where it comes from and what it
//  could not load. Rows are the deck row shape (art, set symbol, name,
//  one line why); a tap opens the viewer with the zoom transition, and
//  when the screen was reached from a deck's add sheet each row has the
//  same "+" the sheet has, so a synergy goes straight into the deck.
//

import SwiftUI
import SwiftData

struct CardSynergiesView: View {
    let item: CardItem
    /// Set when reached from a deck: rows add to its board, and the theme
    /// search stays inside the deck's colour identity.
    var deck: DeckAddSession? = nil

    @Environment(\.modelContext) private var modelContext
    @Namespace private var zoom
    @State private var controller = CardSynergyController()
    @State private var viewer: CardViewerSession?
    @State private var adds = 0
    @State private var error: String?
    /// Sections the user asked to see in full; the rest show `shown` rows.
    @State private var expanded: Set<String> = []

    /// Rows a section shows before "Show All": enough to answer the
    /// question, not a wall.
    private static let shown = 6

    var body: some View {
        ScrollViewReader { proxy in
            List {
                header
                ForEach(controller.sections) { section in
                    self.section(section)
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: viewer?.currentID) { old, id in
                guard old != nil, let id else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(id) }
            }
        }
        .navigationTitle("Synergies")
        .navigationSubtitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: item.id) {
            controller.load(item: item, identity: deck?.identityFilter, container: modelContext.container)
        }
        .fullScreenCover(item: $viewer) { v in
            CardViewerView(items: v.items, currentID: Bindable(v).currentID, deck: v.deck)
                .navigationTransition(.zoom(sourceID: v.currentID ?? "", in: zoom))
        }
        .sensoryFeedback(.success, trigger: adds)
        .alert("Couldn't Update Deck", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                CardArtThumb(artURL: item.artCropURL, fallbackURL: item.imageURL, width: 72, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.headline).lineLimit(1)
                    if let type = item.typeLine {
                        Text(type).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let info = controller.info {
                        HStack(spacing: 8) {
                            if controller.isCommanderPage, let decks = info.numDecks {
                                Text("\(decks.formatted()) decks")
                            } else if let share = info.inclusion {
                                Text("In \(Int((share * 100).rounded()))% of decks")
                            }
                            if let salt = info.salt {
                                Text("Salt \(String(format: "%.2f", salt))")
                                    .foregroundStyle(salt >= 1.2 ? .orange : .secondary)
                            }
                            if let rank = info.rank, controller.isCommanderPage {
                                Text("#\(rank) commander")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("synergies-info")
                    }
                }
            }
            .padding(.vertical, 2)
        } footer: {
            if controller.info != nil {
                Text("EDHREC")
            }
        }
    }

    @ViewBuilder private func section(_ section: CardSynergyController.Section) -> some View {
        Section {
            switch section.state {
            case .loading:
                HStack(spacing: 12) { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
            case .offline:
                Text("Needs a connection.").foregroundStyle(.secondary)
            case .unavailable:
                Text("Couldn't be loaded right now.").foregroundStyle(.secondary)
            case .empty:
                Text(emptyText(for: section.id)).foregroundStyle(.secondary)
            case .ready:
                let all = section.items.ids
                let ids = expanded.contains(section.id) ? all : Array(all.prefix(Self.shown))
                ForEach(ids, id: \.self) { id in
                    if let card = section.items.item(for: id) {
                        row(card, reason: section.reasons[id], in: section)
                            .id(id)
                    }
                }
                if !expanded.contains(section.id) {
                    ForEach(section.unresolved.prefix(max(0, Self.shown - ids.count)), id: \.self) { name in
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(section.unresolved, id: \.self) { name in
                        Text(name).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                let total = all.count + section.unresolved.count
                if !expanded.contains(section.id), total > Self.shown {
                    Button("Show All \(total)") {
                        withAnimation { _ = expanded.insert(section.id) }
                    }
                    .font(.subheadline)
                    .accessibilityIdentifier("synergies-\(section.id)-all")
                }
            }
        } header: {
            Text(section.title)
        } footer: {
            Text(section.footer)
        }
        .accessibilityIdentifier("synergies-\(section.id)")
    }

    private func emptyText(for id: String) -> String {
        switch id {
        case "combos": return "No known combos with this card."
        case "edhrec": return "EDHREC has no page for this card."
        default: return "Nothing in its text to search on."
        }
    }

    private func row(_ card: CardItem, reason: CardReason?, in section: CardSynergyController.Section) -> some View {
        SynergyRow(card: card, reason: reason, inDeck: deck.map { $0.quantity(of: card) }, zoom: zoom,
                   onSetQuantity: { setQuantity(card, $0) }, onOpen: { open(card, in: section) })
    }

    // MARK: Actions

    private func setQuantity(_ card: CardItem, _ quantity: Int) {
        guard let deck else { return }
        do {
            try deck.setQuantity(card, quantity)
            adds += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ card: CardItem, in section: CardSynergyController.Section) {
        viewer = CardViewerSession(items: section.items.items, currentID: card.id, deck: deck)
    }
}

/// The deck search row's shape: art, set symbol, name; cost, the reason,
/// price, ownership. "+" or a stepper when a deck is listening.
private struct SynergyRow: View {
    let card: CardItem
    let reason: CardReason?
    /// Copies on the deck's board, nil when no deck is listening.
    let inDeck: Int?
    let zoom: Namespace.ID
    let onSetQuantity: (Int) -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                CardRowLead(item: card, zoom: zoom) {
                    ReasonDetailLine(reason: reason ?? CardReason(.theme, "Related"), price: card.priceUSD, owned: card.owned)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("synergy-row-\(card.name)")
            if let inDeck {
                if inDeck == 0 {
                    Button {
                        onSetQuantity(1)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add \(card.name)")
                    .accessibilityIdentifier("synergy-add-\(card.name)")
                } else {
                    QuantityStepper(quantity: inDeck, name: card.name, idPrefix: "synergy", onSet: onSetQuantity)
                }
            }
        }
    }
}
