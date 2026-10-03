//
//  CollectionCard.swift
//  magic-hat
//
//  A collection as a card: name, size, market value, a fan of its most
//  valuable cards with its sets and foils beside it, and a thin bar of its
//  colours along the bottom — so a mono-red binder and a five-colour one
//  read apart before their names do. A list says how many of its cards
//  are already owned; an empty one says what to do. Used by the
//  Collections tab and by the picker in the Add sheet (without the value).
//  Glass is affordable here — a handful of these, each a navigation
//  target, unlike the hundreds of content tiles in the grid.
//

import SwiftUI

struct CollectionCard: View {
    let summary: CollectionSummary?
    let name: String
    var showsValue: Bool = true
    /// A list reads as a list: its icon before the name, and its value is
    /// what the cards would cost, not what is held.
    var isList: Bool = false

    @Environment(\.showsPrices) private var showsPrices

    private var valueText: String {
        guard let value = summary?.totalValue, value > 0 else { return "—" }
        return PriceFormat.whole(value)
    }

    private var isEmpty: Bool { summary?.totalCopies == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if isList {
                            Image(systemName: CollectionKind.list.systemImage)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("List")
                        }
                        Text(name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                    }
                    subtitle
                }
                Spacer(minLength: 12)
                if showsValue, showsPrices, !isEmpty {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(summary == nil ? "$0,000" : valueText)
                            .font(.title3.weight(.bold))
                            .monospacedDigit()
                            .redacted(reason: summary == nil ? .placeholder : [])
                        Text(isList ? "TO BUY" : "MARKET")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let s = summary, !s.highlights.isEmpty {
                HStack(alignment: .bottom, spacing: 12) {
                    highlightFan(s.highlights)
                    Spacer(minLength: 0)
                    if showsValue { facts(s) }
                }
            } else if isEmpty, showsValue {
                Label(isList ? "Nothing on it yet — add cards from Search, or import a list."
                      : "Nothing in it yet — add cards from Search, the scanner, or an import.", systemImage: "plus.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let counts = summary?.colorCounts, !counts.isEmpty, !isEmpty {
                ColorBar(counts: counts)
                    .frame(height: 4)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        // The whole card, not just its text: as a Button's label only the
        // drawn content was tappable, and the glass is a background.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// "6,578 cards · 3,861 unique"; on a list "30 cards · 12 owned".
    @ViewBuilder private var subtitle: some View {
        if let s = summary {
            if s.totalCopies == 0 {
                // The empty hint below says it.
                EmptyView()
            } else if isList {
                let owned = s.ownedCopies ?? 0
                Text("\(s.totalCopies.formatted()) cards · \(owned == 0 ? "none owned" : "\(owned.formatted()) owned")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(s.totalCopies.formatted()) cards · \(s.uniqueCards.formatted()) unique")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if showsValue {
            // Not counted yet: a placeholder the count replaces,
            // not a blank that makes the card look empty.
            Text("0,000 cards · 000 unique")
                .font(.caption)
                .foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
        }
    }

    /// Beside the fan: sets and foils, right-aligned.
    private func facts(_ s: CollectionSummary) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let sets = s.sets, sets > 0 { fact(sets, "set", "sets") }
            if let foils = s.foils, foils > 0 { fact(foils, "foil", "foils") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func fact(_ n: Int, _ one: String, _ many: String) -> some View {
        Text("\(n.formatted()) \(n == 1 ? one : many)")
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
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
    }
}

/// The colours of a set of cards as one bar: a segment per colour in
/// WUBRG order, then gold for multicolour and grey for colourless, each
/// as wide as its share. Magic's own palette, deepened so the bar reads
/// on glass.
struct ColorBar: View {
    let counts: [String: Int]

    static func color(_ key: String) -> Color {
        switch key {
        case "W": return Color(red: 0.93, green: 0.86, blue: 0.62)
        case "U": return Color(red: 0.30, green: 0.56, blue: 0.86)
        case "B": return Color(red: 0.36, green: 0.33, blue: 0.42)
        case "R": return Color(red: 0.86, green: 0.34, blue: 0.30)
        case "G": return Color(red: 0.32, green: 0.62, blue: 0.36)
        case "M": return Color(red: 0.84, green: 0.68, blue: 0.27)
        default: return Color(white: 0.72)
        }
    }

    private var segments: [(key: String, share: Double)] {
        let total = Double(counts.values.reduce(0, +))
        guard total > 0 else { return [] }
        return CollectionSummary.colorOrder.compactMap { key in
            guard let n = counts[key], n > 0 else { return nil }
            return (key, Double(n) / total)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let segments = self.segments
            let width = geo.size.width - gap * CGFloat(max(0, segments.count - 1))
            HStack(spacing: gap) {
                ForEach(segments, id: \.key) { segment in
                    Rectangle()
                        .fill(Self.color(segment.key))
                        .frame(width: max(3, width * segment.share))
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let names = ["W": "white", "U": "blue", "B": "black", "R": "red", "G": "green", "M": "multicolour", "C": "colourless"]
        return segments.map { "\(Int(($0.share * 100).rounded()))% \(names[$0.key] ?? $0.key)" }.joined(separator: ", ")
    }
}
