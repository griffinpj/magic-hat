//
//  ManaSymbol.swift
//  magic-hat
//
//  One `{…}` token from a Scryfall mana cost or oracle text, parsed into its
//  parts so a view can draw it: `{W}` is a coloured pip, `{W/U}` a hybrid
//  split, `{2/W}` twobrid, `{W/P}` Phyrexian, `{T}` tap, `{X}` generic. Pure
//  value type — no rendering here — so it is testable and usable off-main.
//

import Foundation

nonisolated enum ManaColor: String, CaseIterable, Codable, Hashable, Sendable {
    case white = "W", blue = "U", black = "B", red = "R", green = "G"

    var name: String {
        switch self {
        case .white: return "White"
        case .blue: return "Blue"
        case .black: return "Black"
        case .red: return "Red"
        case .green: return "Green"
        }
    }
}

nonisolated struct ManaSymbol: Hashable, Sendable {
    /// The token without braces, as Scryfall writes it: "W", "2", "W/U", "T".
    let raw: String

    init(_ raw: String) { self.raw = raw }

    /// Slash-separated parts, uppercased: "W/U" -> ["W", "U"].
    var parts: [String] { raw.split(separator: "/").map { $0.uppercased() } }

    var isHybrid: Bool { parts.count >= 2 }

    /// Phyrexian ({W/P}, {W/U/P}, {P}).
    var isPhyrexian: Bool { parts.last == "P" }

    /// Colours this symbol can be paid with (empty for generic/tap/etc.).
    var colors: [ManaColor] { parts.compactMap { ManaColor(rawValue: $0) } }

    var isGeneric: Bool { parts.count == 1 && Int(raw) != nil }

    /// Pips that draw without a circle behind them (the bolt, planeswalker).
    var drawsBare: Bool { raw.uppercased() == "E" || raw.uppercased() == "PW" || raw.uppercased() == "CHAOS" }

    /// Every `{…}` token in `text`, in order.
    static func parse(_ text: String) -> [ManaSymbol] {
        segments(in: text).compactMap {
            if case .symbol(let s) = $0 { return s } else { return nil }
        }
    }

    /// Mana value of a cost string, Scryfall-style: numbers count as
    /// themselves, X/Y/Z as 0, every other pip as 1, hybrid {2/W} as 2.
    static func manaValue(of cost: String) -> Int {
        parse(cost).reduce(0) { total, symbol in
            if let n = Int(symbol.raw) { return total + n }
            if let first = symbol.parts.first, let n = Int(first) { return total + n }
            switch symbol.raw.uppercased() {
            case "X", "Y", "Z", "T", "Q", "E", "S", "CHAOS", "PW", "A", "TK": return total
            default: return total + 1
            }
        }
    }

    nonisolated enum Segment: Hashable, Sendable {
        case text(String)
        case symbol(ManaSymbol)
    }

    /// Splits text into runs of plain text and symbols, for inline rendering.
    static func segments(in text: String) -> [Segment] {
        var out: [Segment] = []
        var plain = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "{", let close = text[i...].firstIndex(of: "}") {
                let inner = String(text[text.index(after: i)..<close])
                if !inner.isEmpty, !inner.contains(" ") {
                    if !plain.isEmpty { out.append(.text(plain)); plain = "" }
                    out.append(.symbol(ManaSymbol(inner)))
                    i = text.index(after: close)
                    continue
                }
            }
            plain.append(text[i])
            i = text.index(after: i)
        }
        if !plain.isEmpty { out.append(.text(plain)) }
        return out
    }
}
