//
//  CardGridView.swift
//  magic-hat
//
//  Reusable 3-wide card grid driven by a plain [CardItem] array, decoupled
//  from where the cards come from (collection today, Search later). Tapping a
//  tile zooms into the full-screen CardViewerView, which pages through the
//  same items and pushes the detail screen inside its own stack. The parent
//  supplies items and an onAppearIndex callback so it can lazily
//  hydrate/prefetch as tiles approach the viewport.
//
//  The grid also warms images ahead of the viewport: as a tile appears,
//  the next `imageLookahead` tiles' images are fetched and decoded at the
//  tile's size, so a first scroll through a collection meets images that
//  are already in memory rather than placeholders filling in at
//  Scryfall's rate. One warm task at a time, restarted as the user moves.
//

import SwiftUI

/// Images warmed past the tile that appeared; see `CardGridView.warmImages`.
private let gridImageLookahead = 30

struct CardGridView<Header: View, Accessory: View>: View {
    /// Stamped, not compared card by card — see CardItemList.
    let items: CardItemList
    var onAppearIndex: (Int) -> Void = { _ in }
    /// Bump to jump the grid to the top (the parent does this right before
    /// a re-sort lands, so the reorder is laid out from the top instead of
    /// deep into the old order).
    var scrollToTop: Int = 0
    /// Scrolls with the content, above the first row (e.g. suggestion
    /// chips) — inside the scroll view so it never fights the navigation
    /// bar's collapse.
    @ViewBuilder var header: () -> Header
    /// Floating accessory (e.g. a sort button).
    @ViewBuilder var accessory: () -> Accessory

    @Namespace private var zoom
    @Environment(\.displayScale) private var displayScale
    @State private var warmTask: Task<Void, Never>?
    @State private var warmedFrom = -100
    /// The card the viewer was opened on; drives the presentation.
    @State private var viewing: CardItem?
    /// The card the viewer is showing right now — it pages, this follows.
    @State private var viewingID: String?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                header()
                LazyVGrid(columns: columns, spacing: 10) {
                    // Over ids, not cards: SwiftUI compares a ForEach's data
                    // element by element on every update (see CardItemList).
                    ForEach(items.ids, id: \.self) { id in
                        if let item = items.item(for: id) {
                            CardTile(item: item)
                                .equatable()
                                .matchedTransitionSource(id: id, in: zoom)
                                .onAppear {
                                    let index = items.index(of: id) ?? 0
                                    onAppearIndex(index)
                                    warmImages(from: index)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { open(item) }
                        }
                    }
                }
                .padding(10)
            }
            // Search results sit under the keyboard while typing; a scroll
            // should put it away. No-op elsewhere.
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: scrollToTop) { _, _ in
                guard let first = items.first?.id else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(first, anchor: .top) }
            }
            // While the viewer pages, keep the tile it is on in view (the
            // grid is hidden under it, so this is invisible): the zoom-out
            // on dismiss lands on that tile, and the grid is where the user
            // left off. Skipped on open (old == nil) so tapping a
            // half-visible tile doesn't nudge the grid before the zoom.
            .onChange(of: viewingID) { old, id in
                guard old != nil, let id else { return }
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { proxy.scrollTo(id) }
            }
        }
        .overlay(alignment: .bottomTrailing) { accessory() }
        .fullScreenCover(item: $viewing, onDismiss: { viewingID = nil }) { item in
            CardViewerView(items: items, currentID: $viewingID)
                // Follows the pager, so dismissing zooms back to the card
                // the user ended on, not the one they opened.
                .navigationTransition(.zoom(sourceID: viewingID ?? item.id, in: zoom))
        }
    }

    private func open(_ item: CardItem) {
        viewingID = item.id
        viewing = item
    }

    /// Fetch and decode the next window of images at tile size. Restarted
    /// only when the appearing tile has moved a row or so, and cancelled
    /// by the next restart, so a fast scroll doesn't queue windows the
    /// user has already left behind.
    private func warmImages(from index: Int) {
        guard abs(index - warmedFrom) >= 3 else { return }
        warmedFrom = index
        let upper = min(index + gridImageLookahead, items.count)
        guard index < upper else { return }
        let urls = items.items[index..<upper].compactMap(\.imageURL)
        guard !urls.isEmpty else { return }
        let px = CardTile.imageTargetWidth * displayScale
        warmTask?.cancel()
        warmTask = Task(priority: .utility) { await ImageLoader.shared.warm(urls, maxPixel: px) }
    }
}

extension CardGridView where Header == EmptyView, Accessory == EmptyView {
    init(items: CardItemList, onAppearIndex: @escaping (Int) -> Void = { _ in }, scrollToTop: Int = 0) {
        self.init(items: items, onAppearIndex: onAppearIndex, scrollToTop: scrollToTop,
                  header: { EmptyView() }, accessory: { EmptyView() })
    }
}

extension CardGridView where Header == EmptyView {
    init(items: CardItemList, onAppearIndex: @escaping (Int) -> Void = { _ in }, scrollToTop: Int = 0,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(items: items, onAppearIndex: onAppearIndex, scrollToTop: scrollToTop,
                  header: { EmptyView() }, accessory: accessory)
    }
}

extension CardGridView where Accessory == EmptyView {
    init(items: CardItemList, onAppearIndex: @escaping (Int) -> Void = { _ in }, scrollToTop: Int = 0,
         @ViewBuilder header: @escaping () -> Header) {
        self.init(items: items, onAppearIndex: onAppearIndex, scrollToTop: scrollToTop,
                  header: header, accessory: { EmptyView() })
    }
}
