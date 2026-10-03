//
//  SortButton.swift
//  magic-hat
//
//  How every card list sorts: one floating glass button in the list's
//  bottom-trailing corner (above the tab bar), a menu of orders with the
//  current one checked, and Ascending / Descending under a divider, the
//  current way checked. The collection's
//  grid, a deck's list, the deck's add sheet, search results and a set's
//  cards all use it, so sorting looks and works the same wherever it is.
//

import SwiftUI

struct SortButton<Option: Hashable>: View {
    let options: [Option]
    let selected: Option
    let title: (Option) -> String
    let icon: (Option) -> String
    var direction: SortDirection? = nil
    var onDirection: ((SortDirection) -> Void)? = nil
    let onSelect: (Option) -> Void
    var identifier = "sort-button"

    var body: some View {
        Menu {
            // Plain buttons, not a Picker: a Picker inside a Menu builds a
            // nested selection control and is noticeably slower to present.
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    Label(title(option), systemImage: option == selected ? "checkmark" : icon(option))
                }
            }
            if let direction, let onDirection {
                Divider()
                // Both ways listed, the current one checked — a single row
                // that flips reads as the state or the action, never both.
                ForEach([SortDirection.ascending, .descending], id: \.rawValue) { way in
                    Button {
                        onDirection(way)
                    } label: {
                        Label(way == .ascending ? "Ascending" : "Descending",
                              systemImage: way == direction ? "checkmark" : (way == .ascending ? "arrow.up" : "arrow.down"))
                    }
                    .accessibilityIdentifier(way == .ascending ? "sort-ascending" : "sort-descending")
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Sort")
        .accessibilityValue(title(selected))
        .accessibilityIdentifier(identifier)
        .glassEffect(.regular.interactive(), in: Circle())
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }
}

/// The icons every sort shares, so the same order has the same symbol
/// wherever it is offered.
nonisolated enum SortIcon {
    static let name = "textformat"
    static let set = "square.stack.3d.up"
    static let rarity = "star"
    static let price = "dollarsign.circle"
    static let quantity = "number"
    static let recent = "clock"
    static let manaValue = "circle.hexagonpath"
    static let relevance = "wand.and.stars"
    static let released = "calendar"
}
