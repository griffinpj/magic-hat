//
//  CardTile.swift
//  magic-hat
//
//  A single card in the reusable grid: the card image with small overlays for
//  quantity, set code, and collector number. Falls back to a text placeholder
//  before Scryfall metadata is hydrated.
//
//  Driven by the value-type CardItem (not SwiftData models) so it is cheaply
//  Equatable — applied with `.equatable()` at the call site, unchanged tiles
//  skip re-rendering when the surrounding grid updates. Overlays use solid
//  fills rather than materials to avoid per-frame blur cost.
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
    }

    var body: some View {
        CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio)
            .overlay(alignment: .topTrailing) { quantityBadge }
            .overlay(alignment: .bottomLeading) { setInfo }
            .overlay(alignment: .topLeading) { placeholderName }
            .opacity(item.owned ? 1 : 0.55)
    }

    @ViewBuilder private var quantityBadge: some View {
        if item.quantity > 1 {
            Text("×\(item.quantity)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(6)
        }
    }

    private var setInfo: some View {
        HStack(spacing: 4) {
            Text(item.setCode.uppercased())
                .fontWeight(.semibold)
            Text("#\(item.collectorNumber)")
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.6), in: Capsule())
        .padding(6)
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
}
