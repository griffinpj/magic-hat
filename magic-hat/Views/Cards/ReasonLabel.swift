//
//  ReasonLabel.swift
//  magic-hat
//
//  One CardReason as it appears on a row: a small icon and a short
//  phrase, tinted by kind, one line, caption size. Every row that explains
//  a card uses this — recommendations, swaps, synergies — so the eye
//  learns one shape.
//

import SwiftUI

struct ReasonLabel: View {
    let reason: CardReason

    var body: some View {
        Label(reason.text, systemImage: reason.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.medium))
            .foregroundStyle(Self.tint(reason.kind))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    static func tint(_ kind: CardReason.Kind) -> Color {
        switch kind {
        case .combo: return .purple
        case .gap, .source: return .orange
        case .plan, .theme: return .accentColor
        case .meta, .synergy, .popular: return .green
        case .weak: return .secondary
        case .rule: return .red
        }
    }
}

/// The second line of every row that explains a card: the reason, then
/// the price and a check when the card is owned. No mana pips and no
/// "Not owned" here — with a four-pip cost and a price the reason was
/// what got squeezed to "Infini…", and the reason is the point of the
/// row. The cost is one tap away in the viewer.
struct ReasonDetailLine: View {
    let reason: CardReason
    let price: Double?
    let owned: Bool

    var body: some View {
        HStack(spacing: 6) {
            ReasonLabel(reason: reason)
            Spacer(minLength: 4)
            if let price {
                Text(PriceFormat.compact(price)).fixedSize()
            }
            if owned {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Owned")
            }
        }
    }
}
