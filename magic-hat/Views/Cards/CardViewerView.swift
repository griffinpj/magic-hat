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
    /// Stamped, not compared card by card — see CardItemList. The viewer
    /// stays open while hydration batches land behind it.
    let items: CardItemList
    /// The card in the middle. The presenter owns it so it can keep its grid
    /// scrolled to the current card — that is the tile the zoom-out lands on.
    @Binding var currentID: String?
    /// False when the viewer shows other printings from the detail screen:
    /// every printing shares oracle text and rulings, so there is nothing
    /// further to push to.
    var showsDetail: Bool = true
    /// Set when opened from a deck's add sheet: −/+ count and change the
    /// card's copies on that deck's board, instead of Edit/Add/Remove.
    var deck: DeckAddSession? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.modelContext) private var modelContext
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var detail: CardItem?
    @State private var synergies: CardItem?
    @State private var adding: CardItem?
    @State private var editing: CardItem?
    @State private var pendingDelete: CardItem?
    @State private var deleteError: String?
    @State private var deckAdds = 0
    /// What the pager reports as centred. Separate from `currentID`, which
    /// is the truth until the user swipes: see `pager`.
    @State private var visibleID: String?
    @State private var userScrolled = false

    /// Portrait card proportions. Every page is sized the same so the pager
    /// doesn't re-lay out when a landscape (split/battle) card is current.
    private static let cardAspect = 488.0 / 680.0

    private var currentItem: CardItem? {
        guard let currentID else { return items.first }
        return items.item(for: currentID)
    }

    /// Edit and remove act on one owned row. Printings and search hits carry
    /// a Scryfall id, not an entry id — for those, Add is the way in, and
    /// its owned list is where their existing rows get edited or removed.
    private var canEditCurrent: Bool { currentItem?.isEntry ?? false }

    var body: some View {
        NavigationStack {
            viewer
                .navigationDestination(item: $detail) { CardDetailView(item: $0) }
                .navigationDestination(item: $synergies) { CardSynergiesView(item: $0, deck: deck) }
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
        .sensoryFeedback(.success, trigger: deckAdds)
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
            // The cards that work with this one: combos, what is played
            // with it, what shares its theme. Pushed like Details.
            Button("Synergies", systemImage: "link") {
                if let item = currentItem { synergies = item }
            }
            .accessibilityIdentifier("viewer-synergies")
            if deck == nil {
                Button("Edit", systemImage: "pencil") { editing = currentItem }
                    .disabled(!canEditCurrent)
                    .accessibilityIdentifier("viewer-edit")
                Button("Add", systemImage: "plus") { adding = currentItem }
                    .accessibilityIdentifier("viewer-add")
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if let deck {
            // Copies on the deck's board, as a stepper once there are any:
            // adding is one tap, and so is taking it back.
            let count = currentItem.map(deck.quantity(of:)) ?? 0
            if count == 0 {
                ToolbarItem(placement: .bottomBar) {
                    Button("Add to \(deck.board.label)", systemImage: "plus") { setDeckQuantity(1) }
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("viewer-add-deck")
                }
            } else {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Fewer", systemImage: "minus") { setDeckQuantity(count - 1) }
                        .accessibilityIdentifier("viewer-deck-minus")
                    Text("\(count)")
                        .font(.headline)
                        .monospacedDigit()
                        .frame(minWidth: 22)
                        .accessibilityIdentifier("viewer-deck-count")
                        .accessibilityLabel("\(count) in \(deck.board.label)")
                    Button("More", systemImage: "plus") { setDeckQuantity(count + 1) }
                        .accessibilityIdentifier("viewer-deck-plus")
                }
            }
        } else {
            // Remove acts on an owned row; a deck's add sheet shows none, so
            // it isn't offered there rather than shown disabled.
            ToolbarItem(placement: .bottomBar) { removeItem }
        }
    }

    private var removeItem: some View {
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

    // MARK: Pager

    /// The scroll view's position binding is not `currentID` itself. The
    /// pager is laid out while the zoom transition is still growing it out
    /// of the tapped tile, so the card width and the offsets are moving
    /// targets; in that window the scroll view reports whatever ends up
    /// under the anchor — the first card, when the card asked for was the
    /// one right after it, which already peeked in at the edge — and a
    /// direct binding took that as the new current card. So: until the
    /// user swipes, `currentID` is the truth and every size change re-pins
    /// the pager to it; once the user has swiped, the pager is the truth.
    private var pager: some View {
        GeometryReader { geo in
            // Fit by both axes: 80% of the width alone is far taller than the
            // space left in landscape and on iPad, and ran into the panel.
            let cardWidth = min(geo.size.width * 0.80, geo.size.height * Self.cardAspect)
            let sideInset = (geo.size.width - cardWidth) / 2

            ScrollViewReader { proxy in
                pagerContent(cardWidth: cardWidth, height: geo.size.height, sideInset: sideInset)
                    .onAppear { pin(proxy) }
                    .onChange(of: geo.size) { _, _ in
                        if !userScrolled { pin(proxy) }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { userScrolled = true }
                    }
                    .onChange(of: visibleID) { _, id in
                        guard userScrolled, let id, id != currentID else { return }
                        currentID = id
                    }
                    .onChange(of: currentID) { _, id in
                        // Programmatic moves: a tapped neighbour, the step
                        // after a removal.
                        guard let id, id != visibleID else { return }
                        withAnimation(.snappy) { visibleID = id }
                    }
            }
        }
    }

    private func pin(_ proxy: ScrollViewProxy) {
        guard let currentID else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            visibleID = currentID
            proxy.scrollTo(currentID, anchor: .center)
        }
    }

    private func pagerContent(cardWidth: CGFloat, height: CGFloat, sideInset: CGFloat) -> some View {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 14) {
                    ForEach(items.ids, id: \.self) { id in
                        if let item = items.item(for: id) {
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
                                currentID = item.id
                            }
                        }
                        .id(item.id)
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(height: height)
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $visibleID, anchor: .center)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollIndicators(.hidden)
    }

    // MARK: Actions

    private func setDeckQuantity(_ quantity: Int) {
        guard let deck, let item = currentItem else { return }
        do {
            try deck.setQuantity(item, quantity)
            deckAdds += 1
        } catch {
            deleteError = error.localizedDescription
        }
    }

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
    private func reconcile(old: CardItemList, new: CardItemList) {
        guard let currentID, new.item(for: currentID) == nil else { return }
        guard !new.isEmpty else { dismiss(); return }
        let oldIndex = old.index(of: currentID) ?? 0
        self.currentID = new.items[min(oldIndex, new.count - 1)].id
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

/// Every row has a fixed height and is always present, so the panel is
/// the same size for every card and nothing below it moves as the pager
/// goes from an owned foil with a purchase price to a search hit with
/// none: name (with the owned marker trailing), set line (with the
/// language and condition chips trailing when owned), the cost row (empty
/// for a land), the price line (the added date trailing).
private struct InfoPanel: View {
    let item: CardItem

    private static let rowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(item.isEntry ? "\(item.quantity)× \(item.name)" : item.name)
                    .font(.headline)
                    .lineLimit(1)
                if item.isEntry, item.finish != .normal {
                    Text(item.finish.displayName.uppercased())
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.85), in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer(minLength: 0)
                if !item.isEntry, item.owned {
                    Label("In collection", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .fixedSize()
                        .accessibilityIdentifier("viewer-owned")
                }
            }
            .frame(height: Self.rowHeight)

            HStack(spacing: 6) {
                SetSymbolView(setCode: item.setCode, size: 18, tint: .primary, rarity: item.rarity)
                Text("\(item.setName)  #\(item.collectorNumber)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.isEntry {
                    chip(item.language.uppercased())
                    chip(item.condition.replacingOccurrences(of: "_", with: " ").capitalized)
                }
            }
            .frame(height: Self.rowHeight)

            // The cost row is always there — lands have no cost.
            HStack(spacing: 0) {
                if let cost = item.manaCost, !cost.isEmpty {
                    ManaCostView(cost: cost, size: 16)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 16)

            priceLine
                .frame(height: Self.rowHeight)
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
            Spacer(minLength: 0)
            if let added = item.addedDate {
                Text("Added \(added.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
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
