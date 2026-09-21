//
//  CollectionCard.swift
//  magic-hat
//
//  A collection as a card: name, size, optional market value, and a fan of
//  its most valuable cards. Used by the Collections tab and by the picker in
//  the Add sheet (without the value). Glass is affordable here — a handful
//  of these, each a navigation target, unlike the hundreds of content tiles
//  in the grid.
//

import SwiftUI

struct CollectionCard: View {
    let summary: CollectionSummary?
    let name: String
    var showsValue: Bool = true

    private var valueText: String {
        guard let value = summary?.totalValue, value > 0 else { return "—" }
        return value >= 1000 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let s = summary {
                        Text("\(s.totalCopies) cards · \(s.uniqueCards) unique")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                if showsValue {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(valueText)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                        Text("MARKET")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let highlights = summary?.highlights, !highlights.isEmpty {
                highlightFan(highlights)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Overlapped like a hand of cards, most valuable in front.
    private func highlightFan(_ highlights: [CollectionSummary.Highlight]) -> some View {
        HStack(spacing: -22) {
            ForEach(Array(highlights.enumerated().reversed()), id: \.element.id) { index, card in
                CardImageView(
                    urlString: card.imageURL,
                    aspectRatio: card.aspectRatio,
                    cornerRadius: 5,
                    targetWidth: 80
                )
                .frame(width: 50)
                .rotationEffect(.degrees(Double(index) * -2.5))
                .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                .zIndex(Double(highlights.count - index))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 2)
    }
}
