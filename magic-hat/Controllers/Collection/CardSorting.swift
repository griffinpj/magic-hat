//
//  CardSorting.swift
//  magic-hat
//
//  Sort options for a card grid and the comparators behind them. Lives
//  outside any view so it can run off the main actor (the store sorts before
//  handing items over) and so it can be unit tested.
//
//  Every comparator defines a TOTAL order, falling through to name and then
//  id. Swift's sort is not stable, so any key shared by many cards (every
//  card with no price yet, say) would otherwise come back in arbitrary,
//  reshuffling order.
//

import Foundation

/// A collection's orders — the same names, order and icons as a deck's
/// (DeckCardSort) where they overlap, plus what only owned rows have.
nonisolated enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case manaValue = "Mana Value"
    case priceHigh = "Price (High)"
    case priceLow = "Price (Low)"
    case rarity = "Rarity"
    case setCode = "Set"
    case quantity = "Quantity"
    case recent = "Recently Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .name: return SortIcon.name
        case .manaValue: return SortIcon.manaValue
        case .priceHigh: return SortIcon.priceHigh
        case .priceLow: return SortIcon.priceLow
        case .rarity: return SortIcon.rarity
        case .setCode: return SortIcon.set
        case .quantity: return SortIcon.quantity
        case .recent: return SortIcon.recent
        }
    }
}

nonisolated enum CardSorting {
    /// Name order with a total tie-break on id. Uses the precomputed folded
    /// key: plain `<` on two Strings instead of a locale-aware comparison.
    static func byName(_ a: CardItem, _ b: CardItem) -> Bool {
        if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
        return a.id < b.id
    }

    static func sorted(_ items: [CardItem], by sort: CardSort) -> [CardItem] {
        switch sort {
        case .name:
            return items.sorted(by: byName)
        case .setCode:
            return items.sorted {
                if $0.setCode != $1.setCode { return $0.setCode < $1.setCode }
                if $0.collectorNumberValue != $1.collectorNumberValue {
                    return $0.collectorNumberValue < $1.collectorNumberValue
                }
                return byName($0, $1)
            }
        case .rarity:
            return items.sorted {
                if $0.rarityRankValue != $1.rarityRankValue { return $0.rarityRankValue > $1.rarityRankValue }
                return byName($0, $1)
            }
        case .priceHigh:
            return items.sorted {
                // Unpriced sorts to the bottom, then alphabetically.
                let l = $0.marketPrice ?? 0
                let r = $1.marketPrice ?? 0
                if l != r { return l > r }
                return byName($0, $1)
            }
        case .priceLow:
            return items.sorted {
                // Unpriced sorts to the bottom here too.
                let l = $0.marketPrice ?? .infinity
                let r = $1.marketPrice ?? .infinity
                if l != r { return l < r }
                return byName($0, $1)
            }
        case .manaValue:
            return items.sorted {
                let l = ManaSymbol.manaValue(of: $0.manaCost ?? ""), r = ManaSymbol.manaValue(of: $1.manaCost ?? "")
                if l != r { return l < r }
                return byName($0, $1)
            }
        case .quantity:
            return items.sorted {
                if $0.quantity != $1.quantity { return $0.quantity > $1.quantity }
                return byName($0, $1)
            }
        case .recent:
            return items.sorted {
                let l = $0.addedDate ?? .distantPast
                let r = $1.addedDate ?? .distantPast
                if l != r { return l > r }
                return byName($0, $1)
            }
        }
    }
}
