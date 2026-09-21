//
//  CardOverlayView.swift
//  magic-hat
//
//  Full-bleed overlay shown when a card is tapped in the grid. The enlarged
//  card sits in a horizontal pager that peeks the neighbours; swiping left/
//  right flows through every card in the grid. Below is an info panel and a
//  Liquid Glass action bar; the eye action opens the detail screen.
//

import SwiftUI

struct CardOverlayView: View {
    let items: [CardItem]
    let index: Int
    let onClose: () -> Void
    let onOpenDetail: (CardItem) -> Void

    @State private var currentID: String?
    @State private var dragOffset: CGFloat = 0

    private var currentItem: CardItem? {
        guard let currentID else { return items.indices.contains(index) ? items[index] : nil }
        return items.first { $0.id == currentID }
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop reveals the grid behind; tap to dismiss.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 16) {
                Spacer(minLength: 0)
                pager
                if let item = currentItem {
                    InfoPanel(item: item)
                        .transition(.opacity)
                    ActionBar(onEye: { onOpenDetail(item) })
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 24)
            .offset(y: dragOffset)
        }
        .gesture(
            DragGesture()
                .onChanged { v in if v.translation.height > 0 { dragOffset = v.translation.height } }
                .onEnded { v in
                    if v.translation.height > 120 { onClose() }
                    else { withAnimation(.spring) { dragOffset = 0 } }
                }
        )
        .task {
            if currentID == nil, items.indices.contains(index) {
                currentID = items[index].id
            }
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
        }
        .frame(height: UIScreen.main.bounds.height * 0.5)
    }
}

// MARK: - Info panel

private struct InfoPanel: View {
    let item: CardItem

    private var marketPrice: Double? {
        item.finish == .normal ? item.priceUSD : (item.priceUSDFoil ?? item.priceUSD)
    }

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
                SetSymbolView(setCode: item.setCode, size: 18, tint: .secondary)
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

            HStack(spacing: 6) {
                Text("MARKET").font(.caption.weight(.bold)).foregroundStyle(.blue)
                Text(PriceFormat.string(marketPrice))
                    .font(.callout.weight(.semibold))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 20)
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
        HStack(spacing: 28) {
            action("pencil") {}
            action("rectangle.stack.badge.plus") {}
            action("plus.rectangle.on.rectangle") {}
            action("eye", prominent: true, run: onEye)
            action("checkmark.circle") {}
            action("trash") {}
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: Capsule())
    }

    private func action(_ symbol: String, prominent: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 30, height: 30)
                .foregroundStyle(prominent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

/// Formats Scryfall USD prices; nil shows the mock placeholder.
enum PriceFormat {
    static func string(_ value: Double?) -> String {
        guard let value else { return "$xx.xx" }
        return String(format: "$%.2f", value)
    }
}
