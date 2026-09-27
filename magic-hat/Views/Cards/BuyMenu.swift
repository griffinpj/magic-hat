//
//  BuyMenu.swift
//  magic-hat
//
//  "Buy" as a menu of stores, each opening its cart builder prefilled with
//  the cards (see CardStore). Used by a collection's selection bar and
//  "…" menu, and by a deck's missing cards.
//

import SwiftUI

struct BuyMenu: View {
    let title: String
    let lines: [BuyLine]
    /// The bottom bar shows the cart alone; a menu row shows the title.
    var iconOnly = false

    @Environment(\.openURL) private var openURL

    private var copies: Int { lines.reduce(0) { $0 + $1.quantity } }

    var body: some View {
        Menu {
            Section(copies == 1 ? "1 card" : "\(copies) cards") {
                ForEach(CardStore.allCases) { store in
                    Button(store.label, systemImage: "safari") {
                        if let url = store.url(for: lines) { openURL(url) }
                    }
                    .accessibilityIdentifier("buy-\(store.rawValue)")
                }
            }
        } label: {
            if iconOnly {
                Label(title, systemImage: "cart")
            } else {
                Label(title, systemImage: "cart")
                    .labelStyle(.titleAndIcon)
            }
        }
        .disabled(lines.isEmpty)
    }
}
