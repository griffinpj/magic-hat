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
    /// doesn't decode more than it draws. The guess before the grid has
    /// measured itself; see `targetWidth(gridWidth:columns:spacing:)`.
    static func targetWidth(for density: GridDensity) -> CGFloat {
        switch density {
        case .large: return 220
        case .standard: return imageTargetWidth
        case .compact: return 110
        case .dense: return 90
        }
    }

    /// The decode size for a grid of this width: the card's longest edge
    /// in points, as laid out — the tile's width less the cell's margin,
    /// over the card's aspect — rounded up to a multiple of 16 so the
    /// cache key is stable as the width wobbles by a point. The fixed
    /// 150pt guess decoded 450px for a card the 3-wide grid draws at
    /// 516px on a 440pt phone: every tile was upscaled 14%, and soft.
    static func targetWidth(gridWidth: CGFloat, columns: Int, spacing: CGFloat, showsCaption: Bool) -> CGFloat {
        guard gridWidth > 0, columns > 0 else { return imageTargetWidth }
        let tile = (gridWidth - spacing * CGFloat(columns + 1)) / CGFloat(columns)
        let card = tile - (showsCaption ? inset * 2 : 0)
        let longest = card / (488.0 / 680.0)
        return (longest / 16).rounded(.up) * 16
    }

    /// The size the grid last decoded at, for a screen that wants the
    /// grid's image as a stand-in while its own loads (the viewer).
    static var lastTargetWidth: CGFloat = imageTargetWidth

    @ScaledMetric(relativeTo: .caption2) private var symbolSize: CGFloat = 12
    @Environment(\.showsPrices) private var showsPrices
    @Environment(\.colorScheme) private var colorScheme
    /// The art's colours once its image is decoded (`CardImageView` sets
    /// it); the cell glows with them. Seeded from the cache, so a warmed
    /// tile glows in its first frame and the image view's report of the
    /// same colours is a no-op — it used to set nil → found and rebuild
    /// the tile and its cell for no visible change.
    @State private var tint: ArtTint?

    init(item: CardItem, zoom: Namespace.ID? = nil, targetWidth: CGFloat = Self.imageTargetWidth, showsCaption: Bool = true) {
        self.item = item
        self.zoom = zoom
        self.targetWidth = targetWidth
        self.showsCaption = showsCaption
        _tint = State(initialValue: item.displayImageURL.flatMap { ImageMemoryCache.shared.tint($0) })
    }

    static func == (lhs: CardTile, rhs: CardTile) -> Bool {
        let l = lhs.item, r = rhs.item
        guard lhs.targetWidth == rhs.targetWidth, lhs.showsCaption == rhs.showsCaption else { return false }
        guard l.id == r.id, l.quantity == r.quantity, l.displayImageURL == r.displayImageURL,
              l.aspectRatio == r.aspectRatio, l.owned == r.owned, l.finish == r.finish,
              l.inCollection == r.inCollection, l.deckCount == r.deckCount else { return false }
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

    /// Debug kill-switches (Settings › Grid Diagnostics); everything on
    /// in a release build.
    private var diagnostics: GridDiagnostics.Flags { GridDiagnostics.current }

    var body: some View {
        // Up or down since bought, worked out once per body: it reads the
        // display currency from UserDefaults, and the caption's colour, its
        // spoken value and the trend each used to read it again.
        let change = showsPrices ? Self.change(of: item, currency: AppSettings.currency.code) : nil
        tile(change: change)
            // One element for VoiceOver: the card's name (the image says
            // nothing, and the caption alone was "M10 #76, $1.23"), then the
            // rest as its value. A button, since a tap opens the viewer —
            // except an image-less tile, whose name is drawn as text and
            // stays static text (what the seeded UI tests find and tap).
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.name)
            .accessibilityValue(accessibilityValue(change: change))
            .accessibilityRemoveTraits(.isImage)
            .accessibilityAddTraits(item.imageURL == nil ? .isStaticText : .isButton)
    }

    @ViewBuilder private func tile(change: (amount: Double, percent: Double)?) -> some View {
        if showsCaption && diagnostics.caption {
            // The card sits in a Liquid Glass cell that carries on below it
            // with the caption — one object, the card and what it says
            // about itself, rather than text floating under an image. The
            // glass is behind the card (it underlaps it), so the art is
            // never covered; corners concentric with the card's.
            VStack(spacing: 0) {
                image
                caption(change: change)
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, Self.inset)
            .background { cell }
        } else {
            image
        }
    }

    /// `CardItem.gainLoss` with the currency passed in rather than read
    /// per call: nil without a price paid, or when it was paid in another
    /// currency than the one shown.
    static func change(of item: CardItem, currency: String) -> (amount: Double, percent: Double)? {
        guard let market = item.marketPrice, let paid = item.purchasePrice, paid > 0 else { return nil }
        if let paidIn = item.purchaseCurrency, !paidIn.isEmpty, paidIn.uppercased() != currency { return nil }
        let diff = market - paid
        return (diff, diff / paid * 100)
    }

    /// "M10 #76, $1.23, up 12% since bought, Foil, 2 copies, In collection,
    /// In 1 deck" — what the caption and the badges show, spoken.
    private func accessibilityValue(change: (amount: Double, percent: Double)?) -> String {
        var parts = ["\(item.setCode.uppercased()) #\(item.collectorNumber)"]
        if showsPrices, let price = item.marketPrice { parts.append(PriceFormat.tile(price)) }
        let trend = trendLabel(change)
        if !trend.isEmpty { parts.append(trend) }
        if isFoil { parts.append(item.finish.displayName) }
        if item.isEntry, item.quantity > 1 { parts.append("\(item.quantity) copies") }
        if (!item.isEntry && item.owned) || item.inCollection { parts.append("In collection") }
        if item.deckCount > 0 { parts.append(item.deckCount == 1 ? "In 1 deck" : "In \(item.deckCount) decks") }
        return parts.joined(separator: ", ")
    }

    /// The cell, lit by the card's edge: a 3×3 mesh gradient of the
    /// colours sampled just inside the border (`ArtTint`) over a flat
    /// fill, with a hairline rim. Each edge of the cell glows with what the
    /// card has at that edge: a hybrid's split frame bleeds two colours.
    ///
    /// **Not Liquid Glass, deliberately.** It was: a `glassEffect` per
    /// tile. Glass is a live material — every cell sampled, blurred and
    /// refracted what was behind it on every frame of a scroll, and twelve
    /// to fifteen of them at once is what kept the grid off 120Hz on a
    /// ProMotion phone (the main thread was clean; this was the render
    /// server's time). Glass is for the controls that float over content
    /// — the sort button, the bars — not for the content. What is left is
    /// a fill, a mesh and a stroke: three cheap draws, nothing read back,
    /// nothing redrawn as the cell moves.
    private var cell: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cardRadius + Self.inset, style: .continuous)
        let glow = diagnostics.glow ? tint : nil
        return shape
            .fill(Color(.secondarySystemGroupedBackground))
            .overlay {
                if let glow {
                    shape.fill(MeshGradient(width: 3, height: 3, points: ArtTint.meshPoints, colors: glow.colors))
                        .opacity(colorScheme == .dark ? 0.42 : 0.5)
                }
            }
            .overlay {
                // The rim a glass cell had: a light catch on top of the
                // edge, so the cell still reads as a raised object.
                shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.16 : 0.75), lineWidth: 0.5)
            }
    }

    @ViewBuilder private var image: some View {
        // Foils get the static gradient sheen, not the shader: a layer
        // effect is a filter Core Animation runs every composited frame,
        // and a dozen of them scrolling is a shader pass each per frame.
        // The face the user left the card on (a flipped double-faced card
        // stays flipped).
        let art = CardImageView(urlString: diagnostics.images ? item.displayImageURL : nil, aspectRatio: item.aspectRatio,
                                targetWidth: targetWidth, foil: isFoil && diagnostics.sheen, foilSheen: .overlay,
                                tint: showsCaption ? $tint : nil)
            .overlay(alignment: .center) { placeholderName }
            .overlay(alignment: .topTrailing) { deckBadge }
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
    private func caption(change: (amount: Double, percent: Double)?) -> some View {
        HStack(spacing: 4) {
            printing
                .layoutPriority(1)
            Spacer(minLength: 2)
            price(change: change)
                .layoutPriority(2)
        }
        .lineLimit(1)
        // A narrow tile shrinks the line a little before it truncates.
        .minimumScaleFactor(0.75)
        .monospacedDigit()
        .padding(.horizontal, 4)
        .frame(height: Self.captionHeight)
    }

    /// Up since it was bought, down, or neither (no price paid, or paid
    /// in another currency).
    private func trend(_ change: (amount: Double, percent: Double)?) -> Color? {
        guard let change, change.amount != 0 else { return nil }
        return change.amount > 0 ? .green : .red
    }

    /// The market price, led by a foil mark (the sparkles take the foil's
    /// shimmer as a gradient). A quiet dash until prices arrive.
    private func price(change: (amount: Double, percent: Double)?) -> some View {
        HStack(spacing: 2) {
            if isFoil {
                Image(systemName: "sparkles")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(LinearGradient(colors: [.pink, .orange, .cyan],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityLabel(item.finish.displayName)
            }
            // Price and copies as one Text, so a narrow cell shrinks the
            // pair a little rather than truncating either. With prices off
            // the copies stand alone.
            if showsPrices {
                Text("\(Text(item.marketPrice.map { PriceFormat.tile($0) } ?? "—").font(.caption.weight(.semibold)).foregroundStyle(priceStyle(change)))\(countText)")
                    .minimumScaleFactor(0.7)
            } else {
                countText.minimumScaleFactor(0.7)
            }
            ownedMark
        }
    }

    private func priceStyle(_ change: (amount: Double, percent: Double)?) -> AnyShapeStyle {
        if item.marketPrice == nil { return AnyShapeStyle(.tertiary) }
        if let trend = trend(change) { return AnyShapeStyle(trend) }
        return AnyShapeStyle(.primary)
    }

    private func trendLabel(_ change: (amount: Double, percent: Double)?) -> String {
        guard let change, change.amount != 0 else { return "" }
        return change.amount > 0 ? "up \(PriceFormat.percent(change.percent)) since bought" : "down \(PriceFormat.percent(change.percent)) since bought"
    }

    /// Copies, only when there is more than one.
    private var countText: Text {
        guard item.isEntry, item.quantity > 1 else { return Text("") }
        return Text(" ×\(item.quantity)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
    }

    /// A search hit or printing we own somewhere (no quantity of its own),
    /// or a list's row for a card already in a collection.
    @ViewBuilder private var ownedMark: some View {
        if (!item.isEntry && item.owned) || item.inCollection {
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
            // A list's foil or many-copy row that is also owned has the
            // most to say on the price side; the number gives way to it.
            if !(item.inCollection && (isFoil || item.quantity > 1)) {
                Text("#\(item.collectorNumber)")
                    .fixedSize()
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(item.setCode.uppercased()) #\(item.collectorNumber)")
    }

    /// "⧉ 2" in the art's top corner when the card is on a deck list —
    /// the one thing about a card the caption has no room for, and the
    /// place Photos puts a favourite's heart.
    @ViewBuilder private var deckBadge: some View {
        if item.deckCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "rectangle.stack.fill")
                if item.deckCount > 1 { Text("\(item.deckCount)") }
            }
            .font(.system(size: 9, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(4)
            .accessibilityLabel(item.deckCount == 1 ? "In 1 deck" : "In \(item.deckCount) decks")
            .accessibilityIdentifier("tile-decks")
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
