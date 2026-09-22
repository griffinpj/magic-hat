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

import SwiftUI

struct CardGridView<Accessory: View>: View {
    let items: [CardItem]
    var onAppearIndex: (Int) -> Void = { _ in }
    /// Bump to jump the grid to the top (the parent does this right before
    /// a re-sort lands, so the reorder is laid out from the top instead of
    /// deep into the old order).
    var scrollToTop: Int = 0
    /// Floating accessory (e.g. a sort button).
    @ViewBuilder var accessory: () -> Accessory

    @Namespace private var zoom
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
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CardTile(item: item)
                            .equatable()
                            .matchedTransitionSource(id: item.id, in: zoom)
                            .onAppear { onAppearIndex(index) }
                            .contentShape(Rectangle())
                            .onTapGesture { open(item) }
                    }
                }
                .padding(10)
            }
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
}

extension CardGridView where Accessory == EmptyView {
    init(items: [CardItem], onAppearIndex: @escaping (Int) -> Void = { _ in }, scrollToTop: Int = 0) {
        self.init(items: items, onAppearIndex: onAppearIndex, scrollToTop: scrollToTop, accessory: { EmptyView() })
    }
}
