//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: the art, clean, with a two-line caption
//  under it — the way Photos, Music and the App Store caption a grid, and
//  the only way the numbers stay readable over busy card art:
//
//    ✦ $12.34      +87%     price (a foil mark first), change since purchase
//    2× ◆ #123              copies, the set's symbol, the collector number
//
//  Nothing sits on the image except a card's name while it has no art. The
//  caption is fixed-height text, so every row of the grid lines up, and
//  the zoom into the viewer grows out of the art alone (the namespace is
//  applied to the image, not the tile).
//
//  Set symbols come from the Keyrune font or the vectors bundled at build
//  time (see SetIcons); a set neither covers shows its code here rather
//  than asking the WebKit rasterizer, since the grid can show dozens of
//  sets in a scroll.
//
//  Driven by the value-type CardItem so it is cheaply Equatable — applied
//  with `.equatable()` at the call site, unchanged tiles skip re-rendering.
//

import SwiftUI

struct CardTile: View, Equatable {
    let item: CardItem
    /// The zoom transition's namespace; marks the image as its source.
    var zoom: Namespace.ID? = nil

    /// The tile image's longest edge in points; the grid warms images at
    /// this size so a warmed image is the one the tile then finds in
    /// memory.
    static let imageTargetWidth: CGFloat = 150

    @ScaledMetric(relativeTo: .caption2) private var symbolSize: CGFloat = 11

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        let l = lhs.item, r = rhs.item
        guard l.id == r.id, l.quantity == r.quantity, l.imageURL == r.imageURL,
              l.aspectRatio == r.aspectRatio, l.owned == r.owned, l.finish == r.finish else { return false }
        guard l.marketPrice == r.marketPrice, l.purchasePrice == r.purchasePrice else { return false }
        return l.setCode == r.setCode && l.rarity == r.rarity && l.collectorNumber == r.collectorNumber
    }

    private var isFoil: Bool { item.finish != .normal }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            image
            caption
                .padding(.horizontal, 2)
        }
    }

    @ViewBuilder private var image: some View {
        // Sheen on foils, static here so the grid never redraws for it.
        let art = CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                                targetWidth: Self.imageTargetWidth, foil: isFoil)
            .overlay(alignment: .center) { placeholderName }
        if let zoom {
            art.matchedTransitionSource(id: item.id, in: zoom)
        } else {
            art
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            priceLine
            printingLine
        }
    }

    /// The price in the primary colour, led by a foil mark (the sparkles
    /// take the foil's shimmer as a gradient); how it has moved since it
    /// was bought, green or red, trailing. A dash until prices arrive.
    private var priceLine: some View {
        HStack(spacing: 3) {
            if isFoil {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange, .cyan],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel(item.finish.displayName)
            }
            Text(item.marketPrice.map(PriceFormat.compact) ?? "—")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.marketPrice == nil ? .tertiary : .primary)
            Spacer(minLength: 2)
            if let change = item.gainLoss, change.amount != 0 {
                Text(PriceFormat.percent(change.percent))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(change.amount > 0 ? Color.green : Color.red)
                    .accessibilityLabel("\(change.amount > 0 ? "up" : "down") \(PriceFormat.percent(abs(change.percent)))")
            }
        }
        .monospacedDigit()
        .lineLimit(1)
    }

    /// "2× ◆ #123": copies for an owned row (a check for a search hit or a
    /// printing we own somewhere, which has no quantity of its own), the
    /// set's symbol in its rarity's colour, the collector number.
    private var printingLine: some View {
        HStack(spacing: 3) {
            if item.isEntry {
                Text("\(item.quantity)×")
                    .foregroundStyle(.primary)
                    .fontWeight(.semibold)
            } else if item.owned {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if SetSymbolView.drawsWithoutRasterizer(item.setCode) {
                SetSymbolView(setCode: item.setCode, size: symbolSize, tint: .secondary, rarity: item.rarity)
            } else {
                Text(item.setCode.uppercased())
                    .fontWeight(.medium)
            }
            Text("#\(item.collectorNumber)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(printingLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    private var printingLabel: String {
        let printing = "\(item.setCode.uppercased()) #\(item.collectorNumber)"
        if item.isEntry { return "\(item.quantity)× \(printing)" }
        return item.owned ? "In collection, \(printing)" : printing
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
