//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: the art, a couple of badges on it, and a
//  compact caption underneath (set symbol, set code + collector number, and
//  the change in value since it was bought).
//
//  On Liquid Glass: Apple's guidance is that glass belongs to the interactive
//  and navigation layer, not to content — so the floating sort button and the
//  overlay's action bar use it, while these badges use plain translucent
//  capsules. That reading also happens to be what keeps scrolling smooth: a
//  glass (or material) badge is a blur pass, and there are six of them per
//  row. The tile earns its look from typography and spacing instead.
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio)
                .overlay(alignment: .bottomLeading) { quantityBadge }
                .overlay(alignment: .bottomTrailing) { priceBadge }
                .overlay(alignment: .topLeading) { placeholderName }
                .opacity(item.owned ? 1 : 0.55)

            caption
        }
    }

    // MARK: On the art

    private var quantityBadge: some View {
        Text("\(item.quantity)")
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 16)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: Capsule())
            .padding(5)
    }

    @ViewBuilder private var priceBadge: some View {
        if item.marketPrice != nil || item.finish != .normal {
            HStack(spacing: 3) {
                if item.finish != .normal {
                    Text("F")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 13, height: 13)
                        .background(Color.orange, in: Circle())
                }
                if let price = item.marketPrice {
                    Text(PriceFormat.compact(price))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
            }
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
                .multilineTextAlignment(.leading)
                .padding(8)
        }
    }

    // MARK: Under the art

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                SetSymbolView(setCode: item.setCode, size: 12, tint: .secondary)
                Text(item.setCode.uppercased())
                    .font(.caption2.weight(.semibold))
                Text("#\(item.collectorNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)

            if let change = item.gainLoss {
                Text(PriceFormat.change(change.amount, change.percent))
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(change.amount >= 0 ? .green : .red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 2)
    }
}
