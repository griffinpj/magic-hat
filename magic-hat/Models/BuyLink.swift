//
//  BuyLink.swift
//  magic-hat
//
//  Turning a set of cards into a cart at a store: TCGplayer's Mass Entry
//  and Card Kingdom's deck builder both take a list of "4 Lightning Bolt"
//  lines in the URL and open prefilled, the way deck sites send their
//  lists. The store picks printings and conditions there; the app sends
//  names and counts only. A double-faced card goes by its front face,
//  which both stores match.
//

import Foundation

nonisolated struct BuyLine: Hashable, Sendable {
    let name: String
    let quantity: Int
}

nonisolated enum CardStore: String, CaseIterable, Identifiable, Sendable {
    case tcgplayer, cardKingdom

    var id: String { rawValue }
    var label: String { self == .tcgplayer ? "TCGplayer" : "Card Kingdom" }

    /// The store's cart-builder link for `lines`, nil when there is nothing
    /// to buy.
    func url(for lines: [BuyLine]) -> URL? {
        let lines = lines.filter { $0.quantity > 0 }
        guard !lines.isEmpty else { return nil }
        let list = lines.map { "\($0.quantity) \($0.name)" }
        switch self {
        case .tcgplayer:
            return Self.url("https://www.tcgplayer.com/massentry",
                            [("productline", "Magic"), ("c", list.joined(separator: "||"))])
        case .cardKingdom:
            return Self.url("https://www.cardkingdom.com/builder", [("c", list.joined(separator: "\n"))])
        }
    }

    /// Values escaped by hand: URLComponents leaves "&", "+" and "=" in a
    /// query value as they are, and "R&D's Secret Lair" or "Fire // Ice"
    /// has to arrive whole.
    private static func url(_ base: String, _ items: [(String, String)]) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let query = items.map { name, value in
            "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return URL(string: "\(base)?\(query)")
    }

    /// One line per card name, counts summed, in first-seen order — two
    /// printings of Sol Ring are two Sol Rings to buy.
    static func lines(_ cards: [(name: String, quantity: Int)]) -> [BuyLine] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for card in cards where card.quantity > 0 {
            let name = frontFace(card.name)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += card.quantity
        }
        return order.map { BuyLine(name: $0, quantity: counts[$0]!) }
    }

    /// "Delver of Secrets // Insectile Aberration" → "Delver of Secrets".
    static func frontFace(_ name: String) -> String {
        name.components(separatedBy: " // ").first ?? name
    }
}
