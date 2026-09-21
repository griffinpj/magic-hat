//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: just the art, with three small badges on
//  it — quantity top-left, set and collector number bottom-left, market price
//  bottom-right tinted by how it has moved since purchase. No caption beneath,
//  so the grid stays a wall of card art.
//
//  Badges are plain translucent capsules rather than glass or material. Glass
//  belongs to the interactive layer (the floating sort button, the overlay's
//  action bar); a blur per badge would be six blur passes per row, which is
//  exactly what made this grid stutter before. Deliberately no SetSymbolView
//  here either: each distinct set spawns a WKWebView rasterization, and the
//  grid can show dozens of sets in a single scroll.
//
//  Driven by the value-type CardItem so it is cheaply Equatable — applied
//  with `.equatable()` at the call site, unchanged tiles skip re-rendering.
//

import SwiftUI

struct CardTile: View, Equatable {
    let item: CardItem

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        lhs.item.id == rhs.item.id
            && lhs.item.quantity == rhs.item.quantity
            && lhs.item.imageURL == rhs.item.imageURL
            && lhs.item.aspectRatio == rhs.item.aspectRatio
            && lhs.item.owned == rhs.item.owned
            && lhs.item.marketPrice == rhs.item.marketPrice
            && lhs.item.purchasePrice == rhs.item.purchasePrice
            && lhs.item.finish == rhs.item.finish
    }

    /// Green when it has gained, red when it has lost, white when flat or
    /// when we have nothing to compare against.
    private var priceColor: Color {
        guard let change = item.gainLoss, change.amount != 0 else { return .white }
        return change.amount > 0 ? .green : .red
    }

    var body: some View {
        // Sheen on foils, static here so the grid never redraws for it.
        CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                      foil: item.finish != .normal)
            .overlay(alignment: .topLeading) { quantityBadge }
            .overlay(alignment: .bottomLeading) { setBadge }
            .overlay(alignment: .bottomTrailing) { priceBadge }
            .overlay(alignment: .topTrailing) { foilBadge }
            .overlay(alignment: .center) { placeholderName }
            .opacity(item.owned ? 1 : 0.55)
    }

    private var quantityBadge: some View {
        Text("\(item.quantity)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 15)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: Capsule())
            .padding(5)
    }

    @ViewBuilder private var foilBadge: some View {
        if item.finish != .normal {
            Text("F")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(.black)
                .frame(width: 14, height: 14)
                .background(Color.orange, in: Circle())
                .padding(5)
        }
    }

    private var setBadge: some View {
        HStack(spacing: 3) {
            Text(item.setCode.uppercased())
                .fontWeight(.semibold)
            Text("#\(item.collectorNumber)")
                .foregroundStyle(.white.opacity(0.72))
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.62), in: Capsule())
        .padding(5)
    }

    @ViewBuilder private var priceBadge: some View {
        if let price = item.marketPrice {
            Text(PriceFormat.compact(price))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(priceColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.62), in: Capsule())
                .padding(5)
        }
    }

    @ViewBuilder private var placeholderName: some View {
        if item.imageURL == nil {
            Text(item.name)
                .font(.caption2)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }
}
