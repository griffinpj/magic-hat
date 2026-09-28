//
//  CardTile.swift
//  magic-hat
//
//  One card in the reusable grid: the card sitting in a Liquid Glass
//  cell that carries on below it with one line of caption —
//
//    ┌──────────────┐
//    │   the card   │   the glass underlaps the card: a few points of
//    │              │   margin around it, corners concentric with the
//    │              │   card's, and a strip below holding
//    │ ◆ #76  $138 ×2    the set symbol in its rarity's colour, the
//    └──────────────┘   collector number, the price (green above what
//                       was paid, red below), the copies when more than one
//
//  So the card and what it says about itself read as one object, the
//  art is never covered, and every row lines up. The zoom into the viewer
//  grows out of the art alone (the namespace is on the image, not the
//  cell). The densest grid drops the cell and the caption.
//
//  Set symbols come from the Keyrune font or the bundled vectors (see
//  SetIcons); a set neither covers shows its code here rather than asking
//  the WebKit rasterizer, since the grid can show dozens of sets.
//
//  Driven by the value-type CardItem so it is cheaply Equatable — applied
//  with `.equatable()` at the call site, unchanged tiles skip re-rendering.
//

import SwiftUI

struct CardTile: View, Equatable {
    let item: CardItem
    /// The zoom transition's namespace; marks the image as its source.
    var zoom: Namespace.ID? = nil
    /// The image's decode size, from the grid's density (see `targetWidth(for:)`).
    var targetWidth: CGFloat = Self.imageTargetWidth
    /// False in the densest grid, where a caption has no room.
    var showsCaption = true

    /// The tile image's longest edge in points; the grid warms images at
    /// this size so a warmed image is the one the tile then finds in
    /// memory.
    static let imageTargetWidth: CGFloat = 150

    /// Roughly the tile's width on a large phone at each density, so a
    /// two-wide grid isn't a blown-up thumbnail and a five-wide one
    /// doesn't decode more than it draws.
    static func targetWidth(for density: GridDensity) -> CGFloat {
        switch density {
        case .large: return 220
        case .standard: return imageTargetWidth
        case .compact: return 110
        case .dense: return 90
        }
    }

    @ScaledMetric(relativeTo: .caption2) private var symbolSize: CGFloat = 12

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        let l = lhs.item, r = rhs.item
        guard lhs.targetWidth == rhs.targetWidth, lhs.showsCaption == rhs.showsCaption else { return false }
        guard l.id == r.id, l.quantity == r.quantity, l.imageURL == r.imageURL,
              l.aspectRatio == r.aspectRatio, l.owned == r.owned, l.finish == r.finish else { return false }
        guard l.marketPrice == r.marketPrice, l.purchasePrice == r.purchasePrice else { return false }
        return l.setCode == r.setCode && l.rarity == r.rarity && l.collectorNumber == r.collectorNumber
    }

    private var isFoil: Bool { item.finish != .normal }

    /// The glass cell around the card: its margin, and the strip below the
    /// card that holds the caption.
    private static let inset: CGFloat = 5
    private static let captionHeight: CGFloat = 26
    /// The card image's corner radius (CardImageView's default), so the
    /// cell's corners run parallel to the card's.
    private static let cardRadius: CGFloat = 10

    var body: some View {
        if showsCaption {
            // The card sits in a Liquid Glass cell that carries on below it
            // with the caption — one object, the card and what it says
            // about itself, rather than text floating under an image. The
            // glass is behind the card (it underlaps it), so the art is
            // never covered; corners concentric with the card's.
            VStack(spacing: 0) {
                image
                caption
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            .background {
                RoundedRectangle(cornerRadius: Self.cardRadius + Self.inset, style: .continuous)
                    .fill(.clear)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Self.cardRadius + Self.inset, style: .continuous))
            }
        } else {
            image
        }
    }

    @ViewBuilder private var image: some View {
        // Sheen on foils, static here so the grid never redraws for it.
        let art = CardImageView(urlString: item.imageURL, aspectRatio: item.aspectRatio,
                                targetWidth: targetWidth, foil: isFoil)
            .overlay(alignment: .center) { placeholderName }
        if let zoom {
            art.matchedTransitionSource(id: item.id, in: zoom)
        } else {
            art
        }
    }

    /// One line: "◆ #76 · $138 ×2" — the set symbol in its rarity's
    /// colour, the collector number, then the price (green when it is
    /// above what was paid, red below), and the copies when more than one.
    /// The number gives way first when the tile is narrow.
    private var caption: some View {
        HStack(spacing: 4) {
            printing
                .layoutPriority(1)
            Spacer(minLength: 2)
            price
                .layoutPriority(2)
        }
        .lineLimit(1)
        // A narrow tile shrinks the line a little before it truncates.
        .minimumScaleFactor(0.75)
        .monospacedDigit()
        .padding(.horizontal, 4)
        .frame(height: Self.captionHeight)
        .accessibilityElement(children: .combine)
    }

    /// Up since it was bought, down, or neither (no price paid, or paid
    /// in another currency).
    private var trend: Color? {
        guard let change = item.gainLoss, change.amount != 0 else { return nil }
        return change.amount > 0 ? .green : .red
    }

    /// The market price, led by a foil mark (the sparkles take the foil's
    /// shimmer as a gradient). A quiet dash until prices arrive.
    private var price: some View {
        HStack(spacing: 2) {
            if isFoil {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange, .cyan],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel(item.finish.displayName)
            }
            // Price and copies as one Text, so a narrow cell shrinks the
            // pair a little rather than truncating either.
            Text("\(Text(item.marketPrice.map { PriceFormat.tile($0) } ?? "—").font(.caption.weight(.semibold)).foregroundStyle(priceStyle))\(countText)")
                .minimumScaleFactor(0.7)
            ownedMark
        }
        .accessibilityValue(trendLabel)
    }

    private var priceStyle: AnyShapeStyle {
        if item.marketPrice == nil { return AnyShapeStyle(.tertiary) }
        if let trend { return AnyShapeStyle(trend) }
        return AnyShapeStyle(.primary)
    }

    private var trendLabel: String {
        guard let change = item.gainLoss, change.amount != 0 else { return "" }
        return change.amount > 0 ? "up \(PriceFormat.percent(change.percent)) since bought" : "down \(PriceFormat.percent(change.percent)) since bought"
    }

    /// Copies, only when there is more than one.
    private var countText: Text {
        guard item.isEntry, item.quantity > 1 else { return Text("") }
        return Text(" ×\(item.quantity)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }

    /// A search hit or printing we own somewhere (no quantity of its own).
    @ViewBuilder private var ownedMark: some View {
        if !item.isEntry, item.owned {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .accessibilityLabel("In collection")
        }
    }

    /// "◆ #76": the set's symbol in its rarity's colour, the collector number.
    private var printing: some View {
        HStack(spacing: 3) {
            if SetSymbolView.drawsWithoutRasterizer(item.setCode) {
                SetSymbolView(setCode: item.setCode, size: symbolSize, tint: .secondary, rarity: item.rarity)
            } else {
                Text(item.setCode.uppercased())
                    .fontWeight(.medium)
            }
            Text("#\(item.collectorNumber)")
                .fixedSize()
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
