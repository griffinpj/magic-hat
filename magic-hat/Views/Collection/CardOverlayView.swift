//
//  CardOverlayView.swift
//  magic-hat
//
//  Full-bleed overlay shown when a card is tapped. The enlarged card sits in
//  a horizontal pager that peeks the neighbours; swiping flows through the
//  batch. Dismiss with the floating glass X or a swipe down — tapping the
//  dimmed backdrop does NOT dismiss, so a mis-tap near the action bar can't
//  accidentally close it.
//

import SwiftUI

struct CardOverlayView: View {
    let items: [CardItem]
    let onClose: () -> Void
    let onOpenDetail: (CardItem) -> Void

    @State private var currentID: String?

    init(
        items: [CardItem],
        index: Int,
        onClose: @escaping () -> Void,
        onOpenDetail: @escaping (CardItem) -> Void
    ) {
        self.items = items
        self.onClose = onClose
        self.onOpenDetail = onOpenDetail
        // Position the pager on the tapped card up front — no post-appear jump.
        let start = items.indices.contains(index) ? items[index].id : items.first?.id
        _currentID = State(initialValue: start)
    }

    private var currentItem: CardItem? {
        guard let currentID else { return items.first }
        return items.first { $0.id == currentID }
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop; tapping it closes the overlay.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 16) {
                Spacer(minLength: 0)
                pager
                if let item = currentItem {
                    InfoPanel(item: item)
                    ActionBar(onEye: { onOpenDetail(item) })
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 24)
        }
    }

    private var pager: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width * 0.80
            let sideInset = (geo.size.width - cardWidth) / 2

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        CardImageView(
                            urlString: item.imageURL,
                            aspectRatio: item.aspectRatio,
                            cornerRadius: 18,
                            targetWidth: 480
                        )
                        .frame(width: cardWidth)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            // Consume taps on the card so only the backdrop closes the overlay.
            .onTapGesture {}
        }
        // Sized against the container, not UIScreen: correct on rotation,
        // iPad and multitasking.
        .containerRelativeFrame(.vertical) { height, _ in height * 0.52 }
    }
}

// MARK: - Info panel

private struct InfoPanel: View {
    let item: CardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(item.quantity)× \(item.name)")
                    .font(.headline)
                if item.finish != .normal {
                    Text(item.finish.displayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
            }

            HStack(spacing: 6) {
                SetSymbolView(setCode: item.setCode, size: 18, tint: .primary)
                Text("\(item.setName)  #\(item.collectorNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                chip(item.language.uppercased())
                chip(item.condition.replacingOccurrences(of: "_", with: " ").capitalized)
                if !item.binderName.isEmpty { chip(item.binderName, icon: "books.vertical") }
            }

            if let added = item.addedDate {
                Text("Added \(added.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            priceLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var priceLine: some View {
        HStack(spacing: 8) {
            Text("MARKET").font(.caption.weight(.bold)).foregroundStyle(.blue)
            Text(PriceFormat.string(item.marketPrice))
                .font(.callout.weight(.semibold))
            if let delta = gainLoss {
                Text(delta.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(delta.up ? .green : .red)
            }
        }
        .padding(.top, 2)
    }

    /// Market vs. price paid at import.
    private var gainLoss: (text: String, up: Bool)? {
        guard let market = item.marketPrice, let paid = item.purchasePrice, paid > 0 else { return nil }
        let diff = market - paid
        let pct = diff / paid * 100
        let sign = diff >= 0 ? "+" : "-"
        let text = String(format: "(%@$%.2f, %@%.1f%%)", sign, abs(diff), sign, abs(pct))
        return (text, diff >= 0)
    }

    private func chip(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}

// MARK: - Action bar

private struct ActionBar: View {
    let onEye: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            action("pencil") {}
            action("rectangle.stack.badge.plus") {}
            action("plus.rectangle.on.rectangle") {}
            action("eye", prominent: true, run: onEye)
            action("checkmark.circle") {}
            action("trash") {}
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private func action(_ symbol: String, prominent: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

/// Formats Scryfall USD prices; nil shows a dash.
enum PriceFormat {
    static func string(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "$%.2f", value)
    }
}
