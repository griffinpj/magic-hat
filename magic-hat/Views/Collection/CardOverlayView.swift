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
    /// Opens the detail screen for the current card. Nil when the overlay is
    /// already on a detail screen (browsing other printings): every printing
    /// shares the oracle text and rulings, so there is nothing to push to.
    let onOpenDetail: ((CardItem) -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @State private var currentID: String?
    @State private var adding: CardItem?
    @State private var editing: CardItem?
    @State private var pendingDelete: CardItem?
    @State private var deleteError: String?

    init(
        items: [CardItem],
        index: Int,
        onClose: @escaping () -> Void,
        onOpenDetail: ((CardItem) -> Void)?
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
                    InfoPanel(item: item, onDetail: onOpenDetail.map { open in { open(item) } })
                    ActionBar(
                        canEdit: item.owned,
                        onEdit: { editing = item },
                        onAdd: { adding = item },
                        onDelete: { pendingDelete = item }
                    )
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
            guard let item = currentItem else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            // Warm what the detail screen needs: its printings list and its
            // hero art crop (a URL nothing else has fetched).
            let heroPixels = min(1200, 430 * displayScale)
            async let printings: Void = Self.prefetchPrintings(for: item)
            async let art: Void = Self.prefetchArt(for: item, maxPixel: heroPixels)
            _ = await (printings, art)
        }
        .sheet(item: $adding) { AddCardView(item: $0) }
        .sheet(item: $editing) { EditEntryView(item: $0) }
        .confirmationDialog(
            "Remove \(pendingDelete?.name ?? "")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Remove \(item.quantity) from \(item.collectionName)", role: .destructive) { remove(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\(item.setName) #\(item.collectorNumber) · \(item.finish.displayName). Recorded in History.")
        }
        .alert("Couldn't remove", isPresented: Binding(get: { deleteError != nil },
                                                      set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Deletes the entry behind an owned item, then closes: the grid refetches
    /// on the tracker bump and the item is gone from it.
    private func remove(_ item: CardItem) {
        guard let id = UUID(uuidString: item.id) else { return }
        do {
            try CollectionEditController.remove(entryID: id, context: modelContext)
            onClose()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private static func prefetchPrintings(for item: CardItem) async {
        guard let oracleID = item.oracleID,
              PrintingsCache.shared.cached(oracleID: oracleID) == nil else { return }
        await PrintingsCache.shared.prefetch(oracleID: oracleID)
    }

    private static func prefetchArt(for item: CardItem, maxPixel: CGFloat) async {
        guard let url = item.artCropURL else { return }
        _ = try? await ImageLoader.shared.image(for: url, maxPixel: maxPixel)
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
                            fallbackTargetWidth: 150,
                            foil: item.finish != .normal,
                            // Animated only for the card in the middle; neighbours
                            // stay static so the pager isn't redrawing three cards.
                            foilAnimated: isCurrent,
                            foilIntensity: 0.42
                        )
                        .frame(width: cardWidth)
                        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
                        // The whole centred card is the detail target.
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            if isCurrent {
                                onOpenDetail?(item)
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

}

// MARK: - Info panel

private struct InfoPanel: View {
    let item: CardItem
    let onDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(item.quantity)× \(item.name)")
                    .font(.headline)
                if item.finish != .normal {
                    Text(item.finish.displayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer(minLength: 8)
                // Detail affordance, top-right of the info card. A child of
                // the panel, so its tap beats the panel's swallow gesture.
                // Absent when there is no detail screen to go to.
                if let onDetail {
                    Button(action: onDetail) {
                        Image(systemName: "eye")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 36, height: 36)
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityIdentifier("overlay-eye")
                    .accessibilityLabel("Show card details")
                    .offset(x: 4, y: -4)
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
        // Not a target of anything itself; swallow taps so they can't fall
        // through to the backdrop and close the overlay. The eye above is a
        // child, so it still receives its own taps.
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
    /// Edit and remove only make sense for a row we own. Add works for any
    /// card (it's how a printing from the detail screen gets into a
    /// collection). Deck and "mark" actions are still placeholders.
    let canEdit: Bool
    let onEdit: () -> Void
    let onAdd: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            action("pencil", run: onEdit).disabled(!canEdit)
            action("rectangle.stack.badge.plus") {}
            action("plus.rectangle.on.rectangle", run: onAdd)
            action("checkmark.circle") {}
            action("trash", run: onDelete).disabled(!canEdit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }

    private func action(_ symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overlay-\(symbol)")
    }
}
