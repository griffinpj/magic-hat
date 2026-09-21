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
    /// Floating accessory (e.g. a sort button), shown only when no overlay is
    /// open so it never covers the enlarged card.
    @ViewBuilder var accessory: () -> Accessory

    @State private var selectedIndex: Int?
    @State private var detailItem: CardItem?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 10), count: 3
    )

    var body: some View {
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
        .overlay(alignment: .bottomTrailing) {
            if selectedIndex == nil { accessory() }
        }
        .overlay {
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
            }
        }
        .navigationDestination(item: $detailItem) { item in
            CardDetailView(item: item)
        }
    }
}

extension CardGridView where Accessory == EmptyView {
    init(items: [CardItem], onAppearIndex: @escaping (Int) -> Void = { _ in }) {
        self.init(items: items, onAppearIndex: onAppearIndex, accessory: { EmptyView() })
    }
}
