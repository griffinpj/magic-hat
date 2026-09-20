//
//  CardTile.swift
//  magic-hat
//
//  A single card in the collection grid: the card image with small overlays
//  for quantity, set code, and collector number. Falls back to a text
//  placeholder before Scryfall metadata is hydrated.
//
//  Stores plain value types (not the SwiftData models) so it is cheaply
//  Equatable — applied with `.equatable()` at the call site, unchanged tiles
//  skip re-rendering when the surrounding grid updates (e.g. after a
//  hydration save), which keeps scrolling smooth. Overlays use solid fills
//  rather than materials to avoid per-frame blur cost.
//

import SwiftUI

struct CardTile: View, Equatable {
    let name: String
    let setCode: String
    let collectorNumber: String
    let quantity: Int
    let imageURL: String?
    let aspectRatio: Double

    init(entry: CollectionEntry, meta: CardMeta?) {
        self.name = entry.name
        self.setCode = entry.setCode
        self.collectorNumber = entry.collectorNumber
        self.quantity = entry.quantity
        self.imageURL = meta?.imageNormalURL
        self.aspectRatio = meta?.aspectRatio ?? (488.0 / 680.0)
    }

    var body: some View {
        CardImageView(urlString: imageURL, aspectRatio: aspectRatio)
            .overlay(alignment: .topTrailing) { quantityBadge }
            .overlay(alignment: .bottomLeading) { setInfo }
            .overlay(alignment: .topLeading) { placeholderName }
    }

    // Quantity badge, hidden when a single copy.
    @ViewBuilder private var quantityBadge: some View {
        if quantity > 1 {
            Text("×\(quantity)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(6)
        }
    }

    // Set acronym + collector number chip.
    private var setInfo: some View {
        HStack(spacing: 4) {
            Text(setCode.uppercased())
                .fontWeight(.semibold)
            Text("#\(collectorNumber)")
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.caption2)
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.black.opacity(0.6), in: Capsule())
        .padding(6)
    }

    // Shows the name until the image loads, so the tile is never blank.
    @ViewBuilder private var placeholderName: some View {
        if imageURL == nil {
            Text(name)
                .font(.caption2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(8)
        }
    }
}
