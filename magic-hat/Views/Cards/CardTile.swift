//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: just the art, with one row of two small
//  badges along its bottom edge — on the left the copies, the set's symbol
//  in its rarity's colour and the collector number ("2× ◆ #123"), on the
//  right the market price tinted by how it has moved since purchase, led by
//  a foil mark when the printing is foil. Nothing on the top corners, so
//  the art's name and cost stay clear. No caption beneath, so the grid
//  stays a wall of card art.
//
//  Badges are plain translucent capsules rather than glass or material. Glass
//  belongs to the interactive layer that floats over content (the sort
//  button, the viewer's bars); a blur per badge would be two blur passes per
//  tile, which is exactly what made this grid stutter before. Set symbols
//  come from the Keyrune font or the vectors bundled at build time (see
//  SetIcons); a set neither covers shows its code here rather than asking
//  the WebKit rasterizer, since the grid can show dozens of sets in a scroll.
//
//  Driven by the value-type CardItem so it is cheaply Equatable — applied
//  with `.equatable()` at the call site, unchanged tiles skip re-rendering.
//

import SwiftUI

struct CardTile: View, Equatable {
    let item: CardItem

    /// The tile image's longest edge in points; the grid warms images at
    /// this size so a warmed image is the one the tile then finds in
    /// memory.
    static let imageTargetWidth: CGFloat = 150

    /// A notch under caption2 for both badges (a third of a phone's width
    /// holds "2× ◆ #123" and "✦ $12.34" side by side), scaling with it.
    @ScaledMetric(relativeTo: .caption2) private var badgeSize: CGFloat = 10
    @ScaledMetric(relativeTo: .caption2) private var priceSize: CGFloat = 9.5
    @ScaledMetric(relativeTo: .caption2) private var symbolSize: CGFloat = 10.5

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        let l = lhs.item, r = rhs.item
        guard l.id == r.id, l.quantity == r.quantity, l.imageURL == r.imageURL,
              l.aspectRatio == r.aspectRatio, l.owned == r.owned, l.finish == r.finish else { return false }
        guard l.marketPrice == r.marketPrice, l.purchasePrice == r.purchasePrice else { return false }
        return l.setCode == r.setCode && l.rarity == r.rarity && l.collectorNumber == r.collectorNumber
    }

    /// Green when it has gained, red when it has lost, white when flat or
    /// when we have nothing to compare against (search hits, printings).
    private var priceColor: Color {
        guard let change = item.gainLoss, change.amount != 0 else { return .white }
        return change.amount > 0 ? .green : .red
    }

    private var isFoil: Bool { item.finish != .normal }

    var body: some View {
        // Sheen on foils, static here so the grid never redraws for it.
        CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                      targetWidth: Self.imageTargetWidth, foil: isFoil)
            .overlay(alignment: .bottom) {
                // One row, so a long collector number truncates instead of
                // running under the price.
                HStack(alignment: .bottom, spacing: 3) {
                    printingBadge
                    Spacer(minLength: 0)
                    priceBadge.layoutPriority(1)
                }
                .padding(4)
            }
            .overlay(alignment: .center) { placeholderName }
    }

    /// "2× ◆ #123": copies for an owned row (a check for a search hit or a
    /// printing we own somewhere, which has no quantity of its own), then
    /// the set's symbol in its rarity's colour and the collector number.
    private var printingBadge: some View {
        HStack(spacing: 2) {
            if item.isEntry {
                Text("\(item.quantity)×")
                    .fontWeight(.bold)
            } else if item.owned {
                Image(systemName: "checkmark")
                    .font(.system(size: symbolSize * 0.8, weight: .heavy))
                    .foregroundStyle(.green)
            }
            if SetSymbolView.drawsWithoutRasterizer(item.setCode) {
                SetSymbolView(setCode: item.setCode, size: symbolSize, tint: .white, rarity: symbolRarity)
            } else {
                Text(item.setCode.uppercased())
                    .fontWeight(.semibold)
            }
            Text("#\(item.collectorNumber)")
                .foregroundStyle(.white.opacity(0.75))
        }
        .font(.system(size: badgeSize, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.black.opacity(0.62), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(printingLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    /// The printed rarity colours are for a light card frame: uncommon's
    /// silver is too dark on the badge, so it (like common) takes the
    /// badge's white; rare, mythic and special keep theirs.
    private var symbolRarity: String? {
        switch item.rarity.lowercased() {
        case "common", "uncommon": return nil
        default: return item.rarity
        }
    }

    private var printingLabel: String {
        let printing = "\(item.setCode.uppercased()) #\(item.collectorNumber)"
        if item.isEntry { return "\(item.quantity)× \(printing)" }
        return item.owned ? "In collection, \(printing)" : printing
    }

    /// The price, led by a foil mark when the printing is foil (or etched):
    /// the sparkles take the foil's shimmer as a gradient, and the price
    /// keeps its gain/loss colour.
    @ViewBuilder private var priceBadge: some View {
        if item.marketPrice != nil || isFoil {
            HStack(spacing: 1) {
                if isFoil {
                    Image(systemName: "sparkles")
                        .foregroundStyle(LinearGradient(colors: [.pink, .yellow, .cyan],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .accessibilityLabel(item.finish.displayName)
                }
                if let price = item.marketPrice {
                    Text(PriceFormat.compact(price))
                        .foregroundStyle(priceColor)
                }
            }
            .font(.system(size: priceSize, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: Capsule())
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
