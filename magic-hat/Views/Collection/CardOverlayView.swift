//
//  CardOverlayView.swift
//  magic-hat
//
//  Full-bleed overlay shown when a card is tapped. The enlarged card sits in
//  a horizontal pager that peeks the neighbours; swiping flows through the
//  batch. Tapping the centred card (or its corner eye) opens the detail
//  screen; tapping a peeking neighbour scrolls to it; tapping the dimmed
//  backdrop closes the overlay.
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
                    ActionBar()
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 24)
        }
        // Warm the printings cache for whatever card is on screen so the eye
        // action opens instantly. .task(id:) cancels on swipe, and the sleep
        // debounces it — /cards/search is 2/sec, so firing per swipe would
        // queue dozens of requests.
        .task(id: currentID) {
            guard let oracleID = currentItem?.oracleID else { return }
            if PrintingsCache.shared.cached(oracleID: oracleID) != nil { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await PrintingsCache.shared.prefetch(oracleID: oracleID)
        }
    }

    private var pager: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width * 0.80
            let sideInset = (geo.size.width - cardWidth) / 2

            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        let isCurrent = item.id == currentID
                        CardImageView(
                            urlString: item.imageURL,
                            aspectRatio: item.aspectRatio,
                            cornerRadius: 18,
                            targetWidth: 480,
                            fallbackTargetWidth: 150
                        )
                        .frame(width: cardWidth)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        // The whole card is the detail target; the eye in the
                        // corner is the affordance that says so.
                        .overlay(alignment: .topTrailing) {
                            if isCurrent { detailButton(for: item) }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            if isCurrent {
                                onOpenDetail(item)
                            } else {
                                // A peeking neighbour: bring it to the centre
                                // rather than navigating to the wrong card.
                                withAnimation(.snappy) { currentID = item.id }
                            }
                        }
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
        // Sized against the container, not UIScreen: correct on rotation,
        // iPad and multitasking.
        .containerRelativeFrame(.vertical) { height, _ in height * 0.52 }
    }

    private func detailButton(for item: CardItem) -> some View {
        Button { onOpenDetail(item) } label: {
            Image(systemName: "eye")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(10)
        .accessibilityIdentifier("overlay-eye")
        .accessibilityLabel("Show card details")
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
        // Not a target of anything; swallow taps so they can't fall through
        // to the backdrop and close the overlay.
        .contentShape(Rectangle())
        .onTapGesture {}
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
        guard let change = item.gainLoss else { return nil }
        return (PriceFormat.change(change.amount, change.percent), change.amount >= 0)
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
    var body: some View {
        HStack(spacing: 14) {
            action("pencil") {}
            action("rectangle.stack.badge.plus") {}
            action("plus.rectangle.on.rectangle") {}
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
        .accessibilityIdentifier(prominent ? "overlay-eye" : "overlay-\(symbol)")
    }
}
