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
/// (DeckCardSort) where they overlap, plus what only owned rows have. Each
/// runs either way (`SortDirection`); `defaultDirection` is the way it
/// starts — prices and rarity from the top, names from A.
nonisolated enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case manaValue = "Mana Value"
    case price = "Price"
    case rarity = "Rarity"
    case setCode = "Set"
    case quantity = "Quantity"
    case recent = "Recently Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .name: return SortIcon.name
        case .manaValue: return SortIcon.manaValue
        case .price: return SortIcon.price
        case .rarity: return SortIcon.rarity
        case .setCode: return SortIcon.set
        case .quantity: return SortIcon.quantity
        case .recent: return SortIcon.recent
        }
    }

    var defaultDirection: SortDirection {
        switch self {
        case .name, .manaValue, .setCode: return .ascending
        case .price, .rarity, .quantity, .recent: return .descending
        }
    }
}

/// A sort and which way it runs, as the grid and the store's snapshot
/// cache use it. Built from the two stored strings: the sort's raw value
/// ("Price (High)" / "Price (Low)" from before the direction was its own
/// choice still read) and the direction's, empty meaning the sort's own.
nonisolated struct CardOrder: Hashable, Sendable {
    var sort: CardSort
    var direction: SortDirection

    init(_ sort: CardSort = .name, _ direction: SortDirection? = nil) {
        self.sort = sort
        self.direction = direction ?? sort.defaultDirection
    }

    init(sortRaw: String, directionRaw: String) {
        let legacyLow = sortRaw == "Price (Low)"
        let sort = CardSort(rawValue: sortRaw) ?? (sortRaw.hasPrefix("Price") ? .price : .name)
        self.init(sort, SortDirection(rawValue: directionRaw) ?? (legacyLow ? .ascending : nil))
    }

    var key: String { "\(sort.rawValue)|\(direction.rawValue)" }
}

nonisolated enum CardSorting {
    /// Name order with a total tie-break on id. Uses the precomputed folded
    /// key: plain `<` on two Strings instead of a locale-aware comparison.
    static func byName(_ a: CardItem, _ b: CardItem) -> Bool {
        if a.sortKey != b.sortKey { return a.sortKey < b.sortKey }
        return a.id < b.id
    }

    static func sorted(_ items: [CardItem], by order: CardOrder) -> [CardItem] {
        sorted(items, by: order.sort, direction: order.direction)
    }

    /// `direction` nil is the sort's own. Ties always fall through to name
    /// A–Z and then id, whichever way the key runs; cards with no price or
    /// no added date come last either way.
    static func sorted(_ items: [CardItem], by sort: CardSort, direction: SortDirection? = nil) -> [CardItem] {
        let ascending = (direction ?? sort.defaultDirection) == .ascending
        func ordered<K: Comparable>(_ l: K, _ r: K) -> Bool { ascending ? l < r : l > r }
        /// A key some cards lack: those sort last, by name.
        func optional<K: Comparable>(_ key: (CardItem) -> K?) -> [CardItem] {
            items.sorted {
                switch (key($0), key($1)) {
                case let (l?, r?) where l != r: return ordered(l, r)
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byName($0, $1)
                }
            }
        }
        func keyed<K: Comparable>(_ key: (CardItem) -> K) -> [CardItem] {
            items.sorted {
                let l = key($0), r = key($1)
                if l != r { return ordered(l, r) }
                return byName($0, $1)
            }
        }
        switch sort {
        case .name:
            return items.sorted {
                if $0.sortKey != $1.sortKey { return ordered($0.sortKey, $1.sortKey) }
                return $0.id < $1.id
            }
        case .setCode:
            return items.sorted {
                if $0.setCode != $1.setCode { return ordered($0.setCode, $1.setCode) }
                if $0.collectorNumberValue != $1.collectorNumberValue {
                    return ordered($0.collectorNumberValue, $1.collectorNumberValue)
                }
                return byName($0, $1)
            }
        case .rarity: return keyed(\.rarityRankValue)
        case .price: return optional(\.marketPrice)
        case .manaValue: return keyed { ManaSymbol.manaValue(of: $0.manaCost ?? "") }
        case .quantity: return keyed(\.quantity)
        case .recent: return optional(\.addedDate)
        }
    }
}
