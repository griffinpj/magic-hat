//
//  DeckRows.swift
//  magic-hat
//
//  The two row shapes a deck uses: a search result (streamlined, with a
//  "+" so cards go in fast) and a deck-list line (quantity stepper, build
//  status). Both are plain values in, callbacks out. The card part of each
//  row is a plain Button *beside* the controls, not a tap gesture over the
//  whole row: in a List, sibling buttons keep separate hit areas, while a
//  gesture layered over buttons is the classic way taps go missing.
//

import SwiftUI

/// A card found by the deck's search.
struct DeckSearchRow: View {
    let item: CardItem
    /// Copies in the user's collections (nil when unknown/not applicable).
    let ownedCopies: Int?
    /// Copies already on the chosen board.
    let inDeck: Int
    var showsAdd = true
    var notLegal = false
    var onAdd: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onOpen?()
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck-search-row-\(item.name)")
            Spacer(minLength: 8)
            if inDeck > 0 {
                Text("\(inDeck)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel("\(inDeck) in deck")
            }
            if showsAdd {
                Button {
                    onAdd?()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Add \(item.name)")
                .accessibilityIdentifier("deck-search-add-\(item.name)")
            }
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio, cornerRadius: 5, targetWidth: 90)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let cost = item.manaCost, !cost.isEmpty {
                        ManaCostView(cost: cost, size: 13)
                    }
                    if let type = item.typeLine {
                        Text(type).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    if let ownedCopies {
                        Text(ownedCopies > 0 ? "\(ownedCopies) in collection" : "Not in collection")
                            .font(.caption2)
                            .foregroundStyle(ownedCopies > 0 ? .green : .secondary)
                    }
                    if notLegal {
                        Text("Not legal").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
                    if let price = item.priceUSD {
                        Text(PriceFormat.compact(price)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// One line of the deck list.
struct DeckCardRow: View {
    let item: DeckCardItem
    let locked: Bool
    let onSetQuantity: (Int) -> Void
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onOpen?()
            } label: {
                card
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("deck-row-\(item.card.name)")
            .accessibilityValue("\(item.quantity), \(item.status.label)")
            Spacer(minLength: 8)
            if locked {
                Text("×\(item.quantity)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                stepper
            }
        }
    }

    private var card: some View {
        HStack(spacing: 12) {
            CardImageView(urlString: item.card.imageURL, aspectRatio: item.card.aspectRatio, cornerRadius: 5, targetWidth: 90)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.card.name).lineLimit(1)
                HStack(spacing: 6) {
                    if let cost = item.card.manaCost, !cost.isEmpty {
                        ManaCostView(cost: cost, size: 13)
                    }
                    if let price = item.card.priceUSD {
                        Text(PriceFormat.compact(price)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                statusLine
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLine: some View {
        let status = item.status
        let detail: String
        switch status {
        case .built: detail = "In deck"
        case .partiallyBuilt: detail = "\(item.builtQuantity) of \(item.quantity) in deck"
        case .available: detail = "In collection"
        case .partiallyAvailable: detail = "\(item.availableQuantity) of \(item.stillNeeded) in collection"
        case .missing: detail = "Missing"
        }
        return Label(detail, systemImage: status.systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color(for: status))
            .labelStyle(.titleAndIcon)
    }

    private func color(for status: DeckCardStatus) -> Color {
        switch status {
        case .built: return .green
        case .partiallyBuilt, .partiallyAvailable: return .orange
        case .available: return .blue
        case .missing: return .red
        }
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button { onSetQuantity(item.quantity - 1) } label: {
                Image(systemName: "minus").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("Fewer \(item.card.name)")
            Text("\(item.quantity)")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .frame(minWidth: 22)
            Button { onSetQuantity(item.quantity + 1) } label: {
                Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .accessibilityLabel("More \(item.card.name)")
        }
        .buttonStyle(.borderless)
        .font(.body.weight(.medium))
    }
}
