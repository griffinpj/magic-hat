//
//  CardViewerView.swift
//  magic-hat
//
//  Full-screen card viewer, presented with a zoom transition from the tile
//  that was tapped — the Photos pattern. A horizontal pager peeks the
//  neighbours so a swipe flows through the whole batch; the actions live in
//  a native bottom toolbar; the detail screen is *pushed* inside the viewer's
//  own NavigationStack, so popping it lands back on the same card with no
//  state to juggle. Dismiss with the close button, or drag / pinch — the
//  zoom transition's own interactive dismissal, which UIKit direction-locks
//  against the horizontal pager (a custom drag gesture used to fight it).
//
//  This replaced a ZStack overlay drawn inside the pushed screen. That sat
//  *below* the navigation and tab bars, so Back and the tab pill stayed live
//  through the dim; VoiceOver had no way to close it; the card overflowed in
//  landscape and on iPad; and its hand-rolled action bar re-implemented what
//  the toolbar gives for free (glass grouping, labels, hit targets).
//

import SwiftUI

struct CardViewerView: View {
    let items: [CardItem]
    /// The card in the middle. The presenter owns it so it can keep its grid
    /// scrolled to the current card — that is the tile the zoom-out lands on.
    @Binding var currentID: String?
    /// False when the viewer shows other printings from the detail screen:
    /// every printing shares oracle text and rulings, so there is nothing
    /// further to push to.
    var showsDetail: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var detail: CardItem?
    @State private var adding: CardItem?
    @State private var editing: CardItem?
    @State private var pendingDelete: CardItem?
    @State private var deleteError: String?

    /// Portrait card proportions. Every page is sized the same so the pager
    /// doesn't re-lay out when a landscape (split/battle) card is current.
    private static let cardAspect = 488.0 / 680.0

    private var currentItem: CardItem? {
        guard let currentID else { return items.first }
        return items.first { $0.id == currentID }
    }

    /// Edit and remove act on one owned row. Printings and search hits carry
    /// a Scryfall id, not an entry id — for those, Add is the way in, and
    /// its owned list is where their existing rows get edited or removed.
    private var canEditCurrent: Bool { currentItem?.isEntry ?? false }

    var body: some View {
        NavigationStack {
            viewer
                .navigationDestination(item: $detail) { CardDetailView(item: $0) }
        }
    }

    private var viewer: some View {
        layout
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .navigationTitle(currentItem?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // Warm what the detail screen needs for whatever card is in the
        // middle. .task(id:) cancels on swipe and the sleep debounces it —
        // /cards/search is 2/sec, so firing per swipe would queue dozens.
        .task(id: currentID) {
            guard showsDetail, let item = currentItem else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let heroPixels = min(1200, 430 * displayScale)
            async let printings: Void = Self.prefetchPrintings(for: item)
            async let art: Void = Self.prefetchArt(for: item, maxPixel: heroPixels)
            _ = await (printings, art)
        }
        .onChange(of: items) { old, new in reconcile(old: old, new: new) }
        .sheet(item: $adding) { AddCardView(item: $0) }
        .sheet(item: $editing) { EditEntryView(item: $0) }
        .alert("Couldn't remove", isPresented: Binding(get: { deleteError != nil },
                                                      set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    /// Panel under the card in portrait; beside it when the height is
    /// compact (iPhone landscape), where stacking left the card ~70pt tall
    /// under the title bar, panel and toolbar.
    @ViewBuilder private var layout: some View {
        if verticalSizeClass == .compact {
            HStack(spacing: 16) {
                pager
                if let item = currentItem {
                    InfoPanel(item: item)
                        .frame(maxWidth: 340)
                        .padding(.trailing, 20)
                }
            }
        } else {
            VStack(spacing: 16) {
                pager
                if let item = currentItem {
                    InfoPanel(item: item)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    // MARK: Toolbar

    /// Native bars, not a custom capsule: on iOS 26 the bottom bar is Liquid
    /// Glass with grouping, labels, hit targets and disabled dimming for
    /// free. Constructive actions sit together; Remove is separated by a
    /// flexible spacer, as Photos separates its trash. Nothing is shown that
    /// doesn't work — deck and mark actions will join when they exist.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                .accessibilityIdentifier("viewer-close")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if showsDetail {
                Button("Details", systemImage: "info.circle") {
                    if let item = currentItem { detail = item }
                }
                .accessibilityIdentifier("viewer-details")
            }
            Button("Edit", systemImage: "pencil") { editing = currentItem }
                .disabled(!canEditCurrent)
                .accessibilityIdentifier("viewer-edit")
            Button("Add", systemImage: "plus") { adding = currentItem }
                .accessibilityIdentifier("viewer-add")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Remove", systemImage: "trash") { pendingDelete = currentItem }
                .disabled(!canEditCurrent)
                .accessibilityIdentifier("viewer-remove")
                // On the button, not the screen: iOS 26 presents this as a
                // popover anchored to its source, so it points at the trash.
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
        }
    }

    // MARK: Pager

    private var pager: some View {
        GeometryReader { geo in
            // Fit by both axes: 80% of the width alone is far taller than the
            // space left in landscape and on iPad, and ran into the panel.
            let cardWidth = min(geo.size.width * 0.80, geo.size.height * Self.cardAspect)
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
                            // Animated only for the card in the middle; the
                            // neighbours stay static so the pager isn't
                            // redrawing three cards.
                            foilAnimated: isCurrent,
                            foilIntensity: 0.21
                        )
                        .frame(width: cardWidth)
                        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture {
                            if isCurrent {
                                if showsDetail { detail = item }
                            } else {
                                // A peeking neighbour: bring it to the middle
                                // rather than acting on the wrong card.
                                withAnimation(.snappy) { currentID = item.id }
                            }
                        }
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
                .frame(height: geo.size.height)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Actions

    /// Deletes the entry behind an owned item. The presenter's list refetches
    /// on the tracker bump; `reconcile` then steps to the neighbour.
    private func remove(_ item: CardItem) {
        guard let id = UUID(uuidString: item.id) else { return }
        do {
            try CollectionEditController.remove(entryID: id, context: modelContext)
        } catch {
            deleteError = error.localizedDescription
        }
    }

    /// The current card left the list — removed here, or from the Add
    /// sheet's owned rows. Step to the card that took its place, as Photos
    /// does after a delete, and close if nothing is left.
    private func reconcile(old: [CardItem], new: [CardItem]) {
        guard let currentID, !new.contains(where: { $0.id == currentID }) else { return }
        guard !new.isEmpty else { dismiss(); return }
        let oldIndex = old.firstIndex { $0.id == currentID } ?? 0
        self.currentID = new[min(oldIndex, new.count - 1)].id
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
}

// MARK: - Info panel

private struct InfoPanel: View {
    let item: CardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(item.quantity)× \(item.name)")
                    .font(.headline)
                if item.finish != .normal {
                    Text(item.finish.displayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer(minLength: 0)
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
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
