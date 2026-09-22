//
//  CardSearchQuery.swift
//  magic-hat
//
//  Everything a search can filter on, as one Codable value. It is the
//  model behind the filter sheet, the thing a SavedSearch stores, and the
//  source of the Scryfall query string (`scryfallQuery`). Pure and
//  nonisolated so it can be built, compared and serialised anywhere, and
//  so the query builder is unit-testable without a network.
//
//  Search runs on Scryfall rather than the local catalog: its syntax covers
//  every filter here one-to-one (colour maths, legality, price, mana cost
//  containment), it groups printings server-side (`unique:cards`), and it
//  sorts and paginates for us. The local catalog has the rows but none of
//  that logic, and filtering 112k SwiftData objects in memory is exactly the
//  kind of main-thread work this app avoids.
//

import Foundation

// MARK: - Enumerations

nonisolated enum SearchSort: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case name, released, price = "usd", manaValue = "cmc", power, toughness, rarity, color, edhrec, artist, set

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .released: return "Release Date"
        case .price: return "Price"
        case .manaValue: return "Mana Value"
        case .power: return "Power"
        case .toughness: return "Toughness"
        case .rarity: return "Rarity"
        case .color: return "Color"
        case .edhrec: return "EDHREC Rank"
        case .artist: return "Artist"
        case .set: return "Set"
        }
    }

    var systemImage: String {
        switch self {
        case .name: return "textformat"
        case .released: return "calendar"
        case .price: return "dollarsign"
        case .manaValue: return "circle.hexagonpath"
        case .power: return "bolt"
        case .toughness: return "shield"
        case .rarity: return "star"
        case .color: return "paintpalette"
        case .edhrec: return "chart.bar"
        case .artist: return "paintbrush"
        case .set: return "square.stack"
        }
    }

    /// What people expect when they pick the sort: newest first, priciest
    /// first, best-ranked first, otherwise ascending.
    var defaultDirection: SortDirection {
        switch self {
        case .released, .price, .power, .toughness, .rarity: return .descending
        default: return .ascending
        }
    }
}

nonisolated enum SortDirection: String, Codable, Hashable, Sendable {
    case ascending = "asc", descending = "desc"
    var label: String { self == .ascending ? "Ascending" : "Descending" }
}

nonisolated enum MagicFormat: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case standard, pioneer, modern, legacy, vintage, commander, oathbreaker, brawl
    case standardbrawl, alchemy, historic, timeless, pauper, paupercommander, penny
    case premodern, oldschool, duel, future, gladiator, explorer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standardbrawl: return "Standard Brawl"
        case .paupercommander: return "Pauper Commander"
        case .penny: return "Penny Dreadful"
        case .premodern: return "Premodern"
        case .oldschool: return "Old School"
        case .duel: return "Duel Commander"
        case .future: return "Future Standard"
        default: return rawValue.capitalized
        }
    }

    /// The formats most searches care about, shown first.
    static let common: [MagicFormat] = [.standard, .pioneer, .modern, .legacy, .vintage, .commander, .pauper, .brawl]
}

nonisolated enum ColorMode: String, CaseIterable, Codable, Hashable, Sendable {
    /// `c=`: these colours and no others.
    case exactly
    /// `c>=`: at least these colours.
    case including
    /// `c<=`: only these colours (a subset), e.g. what fits a commander.
    case atMost

    var label: String {
        switch self {
        case .exactly: return "Exactly"
        case .including: return "Including"
        case .atMost: return "At Most"
        }
    }

    var scryfallOperator: String {
        switch self {
        case .exactly: return "="
        case .including: return ">="
        case .atMost: return "<="
        }
    }
}

nonisolated enum CardRarity: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case common, uncommon, rare, mythic
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

nonisolated enum CardFinishFilter: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case nonfoil, foil, etched
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nonfoil: return "Non-foil"
        case .foil: return "Foil"
        case .etched: return "Etched"
        }
    }
}

nonisolated enum StatKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case manaValue = "mv", power = "pow", toughness = "tou", loyalty = "loy"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manaValue: return "Mana Value"
        case .power: return "Power"
        case .toughness: return "Toughness"
        case .loyalty: return "Loyalty"
        }
    }
}

nonisolated enum NumericOperator: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case equal = "=", notEqual = "!=", less = "<", lessOrEqual = "<=", greater = ">", greaterOrEqual = ">="
    var id: String { rawValue }
    var label: String {
        switch self {
        case .equal: return "="
        case .notEqual: return "≠"
        case .less: return "<"
        case .lessOrEqual: return "≤"
        case .greater: return ">"
        case .greaterOrEqual: return "≥"
        }
    }
}

nonisolated enum ManaCostMatch: String, CaseIterable, Codable, Hashable, Sendable {
    /// `m:` — the cost contains these symbols.
    case contains
    /// `m=` — the cost is exactly this.
    case exactly
    var label: String { self == .contains ? "Contains" : "Exactly" }
}

// MARK: - Components

/// A word or phrase to match, optionally negated ("is not").
nonisolated struct TextTerm: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    var negated = false

    init(_ text: String, negated: Bool = false) {
        self.text = text
        self.negated = negated
    }
}

nonisolated struct StatConstraint: Codable, Hashable, Sendable, Identifiable {
    var id = UUID()
    var stat: StatKind
    var op: NumericOperator = .equal
    var value: Int

    init(_ stat: StatKind, _ op: NumericOperator = .equal, _ value: Int) {
        self.stat = stat
        self.op = op
        self.value = value
    }
}

nonisolated struct PriceRange: Codable, Hashable, Sendable {
    var min: Double?
    var max: Double?
    var isSet: Bool { min != nil || max != nil }
}

// MARK: - Query

nonisolated struct CardSearchQuery: Codable, Hashable, Sendable {
    /// Free text. Bare words match names; Scryfall syntax typed here passes through.
    var text = ""
    /// Scryfall language code; nil is English. "any" widens to every language.
    var language: String? = nil
    var sort: SearchSort = .name
    /// nil follows the sort's default direction.
    var direction: SortDirection? = nil
    /// One result per card (`unique:cards`) rather than every printing.
    var groupPrintings = true
    /// Hide tokens, emblems, art cards and un-cards.
    var excludeExtras = true

    var formats: Set<MagicFormat> = []

    var colors: Set<ManaColor> = []
    /// Colourless (`c:c`); ignored when `colors` is non-empty.
    var colorless = false
    var colorMode: ColorMode = .exactly
    /// Match colour identity (`id`) instead of printed colour (`c`).
    var useColorIdentity = false
    var minColors: Int? = nil
    var maxColors: Int? = nil

    var typeLine: [TextTerm] = []
    var oracle: [TextTerm] = []

    /// Scryfall cost text, e.g. "{2}{G}{W}". Use `normalizedManaCost(_:)` on user input.
    var manaCost = ""
    var manaCostMatch: ManaCostMatch = .contains

    /// Set codes, lowercase.
    var sets: Set<String> = []
    var rarities: Set<CardRarity> = []
    var price = PriceRange()
    var stats: [StatConstraint] = []
    var finishes: Set<CardFinishFilter> = []
    var artist = ""

    init() {}

    // MARK: Derived

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasColorFilter: Bool { !colors.isEmpty || colorless || minColors != nil || maxColors != nil }

    /// Number of filter *groups* in use — what the Filters button shows.
    /// Options (grouping, extras, language, sort) don't count; they don't
    /// narrow what a card is.
    var activeFilterCount: Int {
        var n = 0
        if !formats.isEmpty { n += 1 }
        if hasColorFilter { n += 1 }
        if !typeLine.isEmpty { n += 1 }
        if !oracle.isEmpty { n += 1 }
        if !manaCost.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        if !sets.isEmpty { n += 1 }
        if !rarities.isEmpty { n += 1 }
        if price.isSet { n += 1 }
        if !stats.isEmpty { n += 1 }
        if !finishes.isEmpty { n += 1 }
        if !artist.trimmingCharacters(in: .whitespaces).isEmpty { n += 1 }
        return n
    }

    var hasFilters: Bool { activeFilterCount > 0 }

    /// Nothing to search for: no text and no filters.
    var isEmpty: Bool { trimmedText.isEmpty && !hasFilters }

    var effectiveDirection: SortDirection { direction ?? sort.defaultDirection }

    var unique: String { groupPrintings ? "cards" : "prints" }

    /// Drops every filter but keeps the text and the options.
    mutating func clearFilters() {
        formats = []
        colors = []; colorless = false; colorMode = .exactly; useColorIdentity = false
        minColors = nil; maxColors = nil
        typeLine = []; oracle = []
        manaCost = ""; manaCostMatch = .contains
        sets = []; rarities = []; price = PriceRange(); stats = []; finishes = []; artist = ""
    }

    // MARK: Display

    /// One line describing the search, for saved-search rows and headers:
    /// "dragon · Modern · R/G · Creature · ≥ $10".
    var summary: String {
        var parts: [String] = []
        let t = trimmedText
        if !t.isEmpty { parts.append("“\(t)”") }
        if !formats.isEmpty {
            parts.append(MagicFormat.allCases.filter { formats.contains($0) }.map(\.label).joined(separator: ", "))
        }
        if !colors.isEmpty {
            let letters = ManaColor.allCases.filter { colors.contains($0) }.map(\.rawValue).joined(separator: "/")
            parts.append(colorMode == .exactly ? letters : "\(colorMode.label.lowercased()) \(letters)")
        } else if colorless {
            parts.append("Colorless")
        }
        if let minColors, let maxColors { parts.append("\(minColors)–\(maxColors) colors") }
        else if let minColors { parts.append("≥ \(minColors) colors") }
        else if let maxColors { parts.append("≤ \(maxColors) colors") }
        if !typeLine.isEmpty {
            parts.append(typeLine.map { ($0.negated ? "not " : "") + $0.text }.joined(separator: ", "))
        }
        if !oracle.isEmpty {
            parts.append(oracle.map { ($0.negated ? "not " : "") + "“\($0.text)”" }.joined(separator: ", "))
        }
        let cost = Self.normalizedManaCost(manaCost)
        if !cost.isEmpty { parts.append(cost) }
        if !sets.isEmpty { parts.append(sets.sorted().map { $0.uppercased() }.joined(separator: ", ")) }
        if !rarities.isEmpty {
            parts.append(CardRarity.allCases.filter { rarities.contains($0) }.map(\.label).joined(separator: ", "))
        }
        if let min = price.min, let max = price.max { parts.append("$\(Self.number(min))–$\(Self.number(max))") }
        else if let min = price.min { parts.append("≥ $\(Self.number(min))") }
        else if let max = price.max { parts.append("≤ $\(Self.number(max))") }
        for c in stats { parts.append("\(c.stat.label) \(c.op.label) \(c.value)") }
        if !finishes.isEmpty {
            parts.append(CardFinishFilter.allCases.filter { finishes.contains($0) }.map(\.label).joined(separator: ", "))
        }
        let a = artist.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { parts.append("by \(a)") }
        return parts.isEmpty ? "All cards" : parts.joined(separator: " · ")
    }

    /// A default name for saving: the text, else the first summary piece.
    var suggestedName: String {
        let t = trimmedText
        if !t.isEmpty { return t.capitalized }
        return summary.components(separatedBy: " · ").first ?? "Search"
    }

    // MARK: Scryfall

    /// The `q` parameter. Order and uniqueness go in their own parameters
    /// (`sort`, `effectiveDirection`, `unique`), not here.
    var scryfallQuery: String {
        var parts: [String] = []

        let t = trimmedText
        if !t.isEmpty { parts.append(t) }

        if let language { parts.append("lang:\(language)") }

        // Scryfall hides tokens/extras by default and includes un-cards;
        // the toggle either hides the un-cards too or shows everything.
        parts.append(excludeExtras ? "-is:funny" : "include:extras")

        for format in formats.sorted(by: { $0.rawValue < $1.rawValue }) {
            parts.append("legal:\(format.rawValue)")
        }

        let colorKey = useColorIdentity ? "id" : "c"
        if !colors.isEmpty {
            let letters = ManaColor.allCases.filter { colors.contains($0) }.map(\.rawValue).joined().lowercased()
            parts.append("\(colorKey)\(colorMode.scryfallOperator)\(letters)")
        } else if colorless {
            parts.append("\(colorKey)=c")
        }
        if let minColors, let maxColors, minColors == maxColors {
            parts.append("\(colorKey)=\(minColors)")
        } else {
            if let minColors { parts.append("\(colorKey)>=\(minColors)") }
            if let maxColors { parts.append("\(colorKey)<=\(maxColors)") }
        }

        for term in typeLine where !term.text.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("\(term.negated ? "-" : "")t:\(Self.quoted(term.text))")
        }
        for term in oracle where !term.text.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("\(term.negated ? "-" : "")o:\(Self.quoted(term.text))")
        }

        let cost = Self.normalizedManaCost(manaCost)
        if !cost.isEmpty {
            parts.append("m\(manaCostMatch == .exactly ? "=" : ":")\(cost)")
        }

        if !sets.isEmpty {
            parts.append(Self.anyOf(sets.sorted().map { "s:\($0.lowercased())" }))
        }
        if !rarities.isEmpty {
            let ordered = CardRarity.allCases.filter { rarities.contains($0) }
            parts.append(Self.anyOf(ordered.map { "r:\($0.rawValue)" }))
        }

        if let min = price.min { parts.append("usd>=\(Self.number(min))") }
        if let max = price.max { parts.append("usd<=\(Self.number(max))") }

        for c in stats {
            parts.append("\(c.stat.rawValue)\(c.op.rawValue)\(c.value)")
        }

        for finish in CardFinishFilter.allCases where finishes.contains(finish) {
            parts.append("is:\(finish.rawValue)")
        }

        let a = artist.trimmingCharacters(in: .whitespaces)
        if !a.isEmpty { parts.append("a:\(Self.quoted(a))") }

        return parts.joined(separator: " ")
    }

    /// Quotes a term when it has spaces or quote characters.
    static func quoted(_ term: String) -> String {
        let t = term.trimmingCharacters(in: .whitespaces)
        let needsQuotes = t.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        guard needsQuotes else { return t }
        return "\"" + t.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func anyOf(_ terms: [String]) -> String {
        terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " or ") + ")"
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// Turns loose input into Scryfall cost text: "2gw" -> "{2}{G}{W}",
    /// "{2}{G/W}" stays, "wubrg" -> "{W}{U}{B}{R}{G}". Unknown characters
    /// are dropped.
    static func normalizedManaCost(_ input: String) -> String {
        var out = ""
        var i = input.startIndex
        var number = ""
        func flushNumber() {
            if !number.isEmpty { out += "{\(number)}"; number = "" }
        }
        while i < input.endIndex {
            let ch = input[i]
            if ch == "{", let close = input[i...].firstIndex(of: "}") {
                flushNumber()
                let inner = input[input.index(after: i)..<close].uppercased()
                if !inner.isEmpty { out += "{\(inner)}" }
                i = input.index(after: close)
                continue
            }
            if ch.isNumber {
                number.append(ch)
            } else {
                flushNumber()
                let u = String(ch).uppercased()
                if ["W", "U", "B", "R", "G", "C", "X", "Y", "Z", "S", "T", "Q", "E", "P"].contains(u) {
                    out += "{\(u)}"
                }
            }
            i = input.index(after: i)
        }
        flushNumber()
        return out
    }
}
