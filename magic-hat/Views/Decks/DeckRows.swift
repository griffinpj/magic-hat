//
//  DeckRows.swift
//  magic-hat
//
//  The two row shapes a deck uses, each two lines tall beside a landscape
//  art crop: a search result (name; cost, type, price, ownership; "+" on
//  the right so cards go in fast) and a deck-list line (name; cost, build
//  status, price; a quantity stepper). Plain values in, callbacks out. The
//  card part of each row is a Button *beside* the controls, not a tap
//  gesture over the whole row: in a List, sibling buttons keep separate
//  hit areas, while a gesture layered over buttons is how taps go missing.
//

import SwiftUI

/// Art, set symbol, name and a caption line — the left side of every deck
/// row. The set symbol leads the name in the rarity's colour, as printed
/// on the card, so the printing and rarity read at a glance. The art is
/// the zoom transition's source when a namespace is given, so the viewer
/// grows out of it and drags back into it, as it does from a grid tile.
struct CardRowLead<Detail: View>: View {
    let item: CardItem
    var zoom: Namespace.ID? = nil
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 12) {
            if let zoom {
                CardArtThumb(artURL: item.artCropURL, fallbackURL: item.imageURL)
                    .matchedTransitionSource(id: item.id, in: zoom)
            } else {
                CardArtThumb(artURL: item.artCropURL, fallbackURL: item.imageURL)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if !item.setCode.isEmpty {
                        SetSymbolView(setCode: item.setCode, size: 15, tint: .primary, rarity: item.rarity)
                    }
                    Text(item.name)
                        .lineLimit(1)
                }
                detail()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A card found by the deck's add sheet (or the commander picker). "+"
/// puts the first copy in; from then on the row is a stepper, so taking
/// a card back out is as quick as adding it.
struct DeckSearchRow: View {
    let item: CardItem
    /// Copies in the user's collections (nil when unknown/not applicable).
    let ownedCopies: Int?
    /// Copies already on the chosen board.
    let inDeck: Int
    var showsAdd = true
    var notLegal = false
    /// Outside the commander's colour identity — tagged, like legality,
    /// rather than hidden, so the user sees why an add would break the deck.
    var offIdentity = false
    /// Why the card is offered (a recommendation): takes the type's place
    /// on the second line, in the standard vocabulary.
    var reason: CardReason? = nil
    var zoom: Namespace.ID? = nil
    var onSetQuantity: ((Int) -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onOpen?()
            } label: {
                CardRowLead(item: item, zoom: zoom) { detail }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck-search-row-\(item.name)")
            if showsAdd {
                if inDeck == 0 {
                    addButton
                } else {
                    QuantityStepper(quantity: inDeck, name: item.name, idPrefix: "deck-search",
                                    onSet: { onSetQuantity?($0) })
                }
            }
        }
    }

    /// Cost, type, price, ownership on one line: everything but the type
    /// keeps its size, so the type is what truncates. (A ViewThatFits over
    /// two variants built both view trees per row — measurable on the
    /// first cells of a debug build.) A recommended card shows the
    /// standard reason line instead.
    @ViewBuilder private var detail: some View {
        if let reason {
            ReasonDetailLine(reason: reason, price: item.priceUSD, owned: (ownedCopies ?? 0) > 0 || item.owned)
        } else {
            plainDetail
        }
    }

    private var plainDetail: some View {
        HStack(spacing: 5) {
            if let cost = item.manaCost, !cost.isEmpty {
                ManaCostView(cost: cost, size: 12)
            }
            if let type = item.typeLine {
                Text(type).truncationMode(.tail).layoutPriority(-1)
            }
            if let price = item.priceUSD {
                Text(PriceFormat.compact(price)).fixedSize()
            }
            if let ownedCopies {
                Text(ownedCopies > 0 ? "\(ownedCopies) owned" : "Not owned")
                    .foregroundStyle(ownedCopies > 0 ? .green : .secondary)
                    .fixedSize()
            }
            if notLegal {
                Text("Not legal")
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .fixedSize()
            }
            if offIdentity {
                Text("Outside identity")
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .fixedSize()
            }
        }
    }

    private var addButton: some View {
        Button {
            onSetQuantity?(1)
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Add \(item.name)")
        .accessibilityIdentifier("deck-search-add-\(item.name)")
    }
}

/// One line of the deck list.
struct DeckCardRow: View {
    let item: DeckCardItem
    let locked: Bool
    var zoom: Namespace.ID? = nil
    let onSetQuantity: (Int) -> Void
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onOpen?()
            } label: {
                CardRowLead(item: item.card, zoom: zoom) { detail }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck-row-\(item.card.name)")
            .accessibilityValue("\(item.quantity), \(item.status.label)")
            if locked {
                Text("×\(item.quantity)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                QuantityStepper(quantity: item.quantity, name: item.card.name, idPrefix: "deck", onSet: onSetQuantity)
            }
        }
    }

    /// Cost, build status and price on one line; the status truncates
    /// before the price disappears.
    private var detail: some View {
        HStack(spacing: 5) {
            if let cost = item.card.manaCost, !cost.isEmpty {
                ManaCostView(cost: cost, size: 12)
            }
            Label(statusText, systemImage: item.status.systemImage)
                .labelStyle(.titleAndIcon)
                .fontWeight(.medium)
                .foregroundStyle(color(for: item.status))
                .layoutPriority(-1)
            if let price = item.card.priceUSD {
                Text(PriceFormat.compact(price)).fixedSize()
            }
        }
    }

    private var statusText: String {
        switch item.status {
        case .built: return "In deck"
        case .partiallyBuilt: return "\(item.builtQuantity) of \(item.quantity) in deck"
        case .available: return "In collection"
        case .partiallyAvailable: return "\(item.availableQuantity) of \(item.stillNeeded) in collection"
        case .missing: return "Missing"
        }
    }

    private func color(for status: DeckCardStatus) -> Color {
        switch status {
        case .built: return .green
        case .partiallyBuilt, .partiallyAvailable: return .orange
        case .available: return .blue
        case .missing: return .red
        }
    }
}

/// The −/n/+ beside a row. Accessibility names follow the card ("Fewer
/// Lightning Bolt"), and ids the prefix, so tests can find one row's.
struct QuantityStepper: View {
    let quantity: Int
    let name: String
    var idPrefix = "deck"
    let onSet: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button("minus", label: "Fewer \(name)", id: "\(idPrefix)-minus-\(name)") { onSet(quantity - 1) }
            Text("\(quantity)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 18)
            button("plus", label: "More \(name)", id: "\(idPrefix)-plus-\(name)") { onSet(quantity + 1) }
        }
        .buttonStyle(.borderless)
    }

    private func button(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 26, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
