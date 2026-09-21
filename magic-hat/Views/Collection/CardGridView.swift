//
//  CardGridView.swift
//  magic-hat
//
//  Reusable 3-wide card grid driven by a plain [CardItem] array, decoupled
//  from where the cards come from (collection today, Search later). Tapping a
//  card opens a paged overlay; the "eye" action in the overlay pushes the
//  detail screen. The parent supplies items and an onAppearIndex callback so
//  it can lazily hydrate/prefetch as tiles approach the viewport.
//

import SwiftUI

struct CardGridView<Accessory: View>: View {
    let items: [CardItem]
    var onAppearIndex: (Int) -> Void = { _ in }
    /// Bump to jump the grid to the top (the parent does this right before
    /// a re-sort lands, so the reorder is laid out from the top instead of
    /// deep into the old order).
    var scrollToTop: Int = 0
    /// Floating accessory (e.g. a sort button), shown only when no overlay is
    /// open so it never covers the enlarged card.
    @ViewBuilder var accessory: () -> Accessory

    @State private var selectedIndex: Int?
    @State private var detailItem: CardItem?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    var body: some View {
        ZStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            CardTile(item: item)
                                .equatable()
                                .onAppear { onAppearIndex(index) }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = index }
                                }
                        }
                    }
                    .padding(10)
                }
                .onChange(of: scrollToTop) { _, _ in
                    guard let first = items.first?.id else { return }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { proxy.scrollTo(first, anchor: .top) }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selectedIndex == nil { accessory() }
            }

            // Overlay as a top-level sibling so it fully intercepts scrolling
            // and taps — the collection behind can't be interacted with; only a
            // tap on the dimmed backdrop closes it.
            if let index = selectedIndex, items.indices.contains(index) {
                CardOverlayView(
                    items: items,
                    index: index,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.2)) { selectedIndex = nil }
                    },
                    onOpenDetail: { item in
                        // Keep the overlay state so popping detail returns to it.
                        detailItem = item
                    }
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .navigationDestination(item: $detailItem) { item in
            CardDetailView(item: item)
        }
    }
}

extension CardGridView where Accessory == EmptyView {
    init(items: [CardItem], onAppearIndex: @escaping (Int) -> Void = { _ in }, scrollToTop: Int = 0) {
        self.init(items: items, onAppearIndex: onAppearIndex, scrollToTop: scrollToTop, accessory: { EmptyView() })
    }
}
