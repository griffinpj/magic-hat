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

nonisolated enum CardSort: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case setCode = "Set"
    case rarity = "Rarity"
    case priceHigh = "Price (High)"
    case quantity = "Quantity"
    case recent = "Recently Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .setCode: return "square.stack.3d.up"
        case .rarity: return "sparkles"
        case .priceHigh: return "dollarsign.circle"
        case .quantity: return "number"
        case .recent: return "clock"
        }
    }
}

nonisolated enum CardSorting {
    /// Rarity ordering, low → high. Unknown rarity sorts lowest.
    static let rarityRank: [String: Int] = [
        "common": 0, "uncommon": 1, "rare": 2, "mythic": 3, "special": 4, "bonus": 5
    ]

    static func byName(_ a: CardItem, _ b: CardItem) -> Bool {
        let c = a.name.localizedCaseInsensitiveCompare(b.name)
        if c != .orderedSame { return c == .orderedAscending }
        return a.id < b.id
    }

    static func sorted(_ items: [CardItem], by sort: CardSort) -> [CardItem] {
        switch sort {
        case .name:
            return items.sorted(by: byName)
        case .setCode:
            return items.sorted {
                if $0.setCode != $1.setCode { return $0.setCode < $1.setCode }
                let l = Int($0.collectorNumber) ?? Int.max
                let r = Int($1.collectorNumber) ?? Int.max
                if l != r { return l < r }
                return byName($0, $1)
            }
        case .rarity:
            return items.sorted {
                let l = rarityRank[$0.rarity.lowercased()] ?? -1
                let r = rarityRank[$1.rarity.lowercased()] ?? -1
                if l != r { return l > r }
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
