//
//  CardTile.swift
//  magic-hat
//
//  A single card in the collection grid: the card image with small
//  overlays for quantity, set code, and collector number. Falls back to a
//  text placeholder before Scryfall metadata is hydrated.
//

import SwiftUI

struct CardTile: View {
    let entry: CollectionEntry
    let meta: CardMeta?

    private var aspectRatio: Double {
        meta?.aspectRatio ?? (488.0 / 680.0)
    }

    var body: some View {
        CardImageView(urlString: meta?.imageNormalURL, aspectRatio: aspectRatio)
            .overlay(alignment: .topTrailing) { quantityBadge }
            .overlay(alignment: .bottomLeading) { setInfo }
            .overlay(alignment: .topLeading) { placeholderName }
    }

    // Quantity badge, hidden when a single copy.
    @ViewBuilder private var quantityBadge: some View {
        if entry.quantity > 1 {
            Text("×\(entry.quantity)")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
    }

    // Set acronym + collector number chip.
    private var setInfo: some View {
        HStack(spacing: 4) {
            Text(entry.setCode.uppercased())
                .fontWeight(.semibold)
            Text("#\(entry.collectorNumber)")
                .foregroundStyle(.secondary)
        }
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(6)
    }

    // Shows the name until the image loads, so the tile is never blank.
    @ViewBuilder private var placeholderName: some View {
        if meta?.imageNormalURL == nil {
            Text(entry.name)
                .font(.caption2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .padding(8)
        }
    }
}
