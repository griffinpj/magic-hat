//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: the art, clean, and a two-line caption
//  beneath it, in the register of Photos' and the App Store's grids — one
//  number that matters in primary, everything else quiet:
//
//    $138                ×2      the price (a foil mark first); the copies,
//                                as a small count, only when there is more
//                                than one — the common case stays clean
//    ◆ #76                       the set's symbol in its rarity's colour
//                                and the collector number, secondary
//
//  No badges on the image: card art is busy, and text over it fights the
//  card's own frame. The caption is fixed-height text, so every row of the
//  grid lines up, and the zoom into the viewer grows out of the art alone
//  (the namespace is applied to the image, not the tile).
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

    @ScaledMetric(relativeTo: .caption2) private var symbolSize: CGFloat = 12

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        let l = lhs.item, r = rhs.item
        guard l.id == r.id, l.quantity == r.quantity, l.imageURL == r.imageURL,
              l.aspectRatio == r.aspectRatio, l.owned == r.owned, l.finish == r.finish else { return false }
        guard l.marketPrice == r.marketPrice else { return false }
        return l.setCode == r.setCode && l.rarity == r.rarity && l.collectorNumber == r.collectorNumber
    }

    private var isFoil: Bool { item.finish != .normal }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                price
                Spacer(minLength: 4)
                count
            }
            printing
        }
        .lineLimit(1)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    /// The market price, led by a foil mark (the sparkles take the foil's
    /// shimmer as a gradient). A quiet dash until prices arrive.
    private var price: some View {
        HStack(spacing: 3) {
            if isFoil {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange, .cyan],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel(item.finish.displayName)
            }
            Text(item.marketPrice.map(PriceFormat.compact) ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(item.marketPrice == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
    }

    /// Copies, as a small count, only when there is more than one; a
    /// search hit or printing we own somewhere (no quantity of its own)
    /// gets a check instead.
    @ViewBuilder private var count: some View {
        if item.isEntry, item.quantity > 1 {
            Text("×\(item.quantity)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(.quaternary, in: Capsule())
                .accessibilityLabel("\(item.quantity) copies")
        } else if !item.isEntry, item.owned {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel("In collection")
        }
    }

    /// "◆ #76": the set's symbol in its rarity's colour, the collector number.
    private var printing: some View {
        HStack(spacing: 4) {
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
        .accessibilityLabel("\(item.setCode.uppercased()) #\(item.collectorNumber)")
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
