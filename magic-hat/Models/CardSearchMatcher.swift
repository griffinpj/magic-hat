//
//  CardSearchMatcher.swift
//  magic-hat
//
//  `CardSearchQuery.matches` made cheap enough to run per keystroke over a
//  whole collection. It used to call `range(of:options:
//  [.caseInsensitive, .diacriticInsensitive])` per word × four fields ×
//  3,900 cards — a locale-aware compare that folds both strings on every
//  call — and re-normalised and re-parsed the wanted mana cost per card.
//  Now both sides are folded once: the query's words and terms when the
//  matcher is built, a card's name / type line / rules text / set name /
//  artist the first time any search asks (`CardSearchCache`, a box every
//  copy of the CardItem shares), and the comparison is a byte search over
//  UTF-8. The answers are the same — CardSearchQueryMatchingTests.
//

import Foundation
import Synchronization

/// Folding for in-memory search: case and diacritics, as Scryfall ignores
/// them ("Jötun" finds "jotun"; "ÉLDER" finds "Elder").
nonisolated enum CardSearchFolding {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether folded `needle` occurs in folded `haystack`, by bytes.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var h = haystack, n = needle
        return h.withUTF8 { hb in
            n.withUTF8 { nb in
                guard nb.count <= hb.count, let hp = hb.baseAddress, let np = nb.baseAddress else { return false }
                return memmem(hp, hb.count, np, nb.count) != nil
            }
        }
    }
}

/// What in-memory search reads of a card, folded and parsed once, lazily.
/// A reference, so the CardItem stays a cheap value: copies share it, and
/// it takes no part in equality or hashing (the fields it is made from do).
nonisolated final class CardSearchCache: Sendable, Hashable {
    struct Folded: Sendable {
        let name: String
        let typeLine: String
        let oracleText: String
        let setName: String
        let artist: String
    }

    private struct State {
        var folded: Folded?
        var manaSymbols: [ManaSymbol]?
        var manaValue: Int?
    }

    private let state = Mutex(State())

    init() {}

    func folded(_ item: CardItem) -> Folded {
        if let done = state.withLock({ $0.folded }) { return done }
        // Folded outside the lock: two threads racing make the same value.
        let f = Folded(name: CardSearchFolding.fold(item.name),
                       typeLine: CardSearchFolding.fold(item.typeLine ?? ""),
                       oracleText: CardSearchFolding.fold(item.oracleText ?? ""),
                       setName: CardSearchFolding.fold(item.setName),
                       artist: CardSearchFolding.fold(item.artist ?? ""))
        state.withLock { $0.folded = f }
        return f
    }

    func manaSymbols(_ item: CardItem) -> [ManaSymbol] {
        if let done = state.withLock({ $0.manaSymbols }) { return done }
        let parsed = ManaSymbol.parse(item.manaCost ?? "")
        state.withLock { $0.manaSymbols = parsed }
        return parsed
    }

    func manaValue(_ item: CardItem) -> Int {
        if let done = state.withLock({ $0.manaValue }) { return done }
        let value = ManaSymbol.manaValue(of: item.manaCost ?? "")
        state.withLock { $0.manaValue = value }
        return value
    }

    static func == (a: CardSearchCache, b: CardSearchCache) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// A `CardSearchQuery` prepared for evaluating many cards: everything the
/// query contributes is folded, lowercased or parsed here, once.
nonisolated struct CardSearchMatcher: Sendable {
    /// Included and excluded terms of one group, folded.
    struct Terms: Sendable {
        let included: [String]
        let excluded: [String]
        let match: TermMatch

        init(_ terms: [TextTerm], match: TermMatch) {
            included = terms.included.map { CardSearchFolding.fold($0.text) }
            excluded = terms.excluded.map { CardSearchFolding.fold($0.text) }
            self.match = match
        }

        var isEmpty: Bool { included.isEmpty && excluded.isEmpty }

        /// Every included term (or any, with `.any`) in folded `text`, no
        /// excluded one.
        func matches(_ text: String) -> Bool {
            if !included.isEmpty {
                let hit: Bool
                switch match {
                case .all: hit = included.allSatisfy { CardSearchFolding.contains(text, $0) }
                case .any: hit = included.contains { CardSearchFolding.contains(text, $0) }
                }
                if !hit { return false }
            }
            return !excluded.contains { CardSearchFolding.contains(text, $0) }
        }
    }

    let query: CardSearchQuery
    private let words: [String]
    private let typeTerms: Terms
    private let oracleTerms: Terms
    private let wantedCost: [ManaSymbol]?
    private let setCodes: Set<String>
    private let rarities: Set<String>
    private let artist: String
    private let cardColorsFilter: Bool

    init(_ query: CardSearchQuery) {
        self.query = query
        words = query.trimmedText.split(whereSeparator: \.isWhitespace).map { CardSearchFolding.fold(String($0)) }
        typeTerms = Terms(query.typeLine, match: query.typeLineMatch)
        oracleTerms = Terms(query.oracle, match: query.oracleMatch)
        let cost = CardSearchQuery.normalizedManaCost(query.manaCost)
        wantedCost = cost.isEmpty ? nil : ManaSymbol.parse(cost)
        setCodes = Set(query.sets.map { $0.lowercased() })
        rarities = Set(query.rarities.map(\.rawValue))
        artist = CardSearchFolding.fold(query.artist.trimmingCharacters(in: .whitespaces))
        cardColorsFilter = !query.colors.isEmpty || query.colorless || query.minColors != nil || query.maxColors != nil
    }

    func matches(_ item: CardItem) -> Bool {
        let q = query
        let needsText = !words.isEmpty || !typeTerms.isEmpty || !oracleTerms.isEmpty || !artist.isEmpty
        let folded = needsText ? item.searchCache.folded(item) : nil
        if let folded, !words.isEmpty {
            for w in words {
                if !CardSearchFolding.contains(folded.name, w), !CardSearchFolding.contains(folded.typeLine, w),
                   !CardSearchFolding.contains(folded.oracleText, w), !CardSearchFolding.contains(folded.setName, w) {
                    return false
                }
            }
        }
        if let language = q.language, language != "any", item.language.lowercased() != language { return false }
        for format in q.formats where item.legalities?[format.rawValue] != "legal" { return false }

        if cardColorsFilter {
            let cardColors = Set(q.useColorIdentity ? item.colorIdentity : item.colors)
            if !q.colors.isEmpty {
                switch q.colorMode {
                case .exactly: if cardColors != q.colors { return false }
                case .including: if !cardColors.isSuperset(of: q.colors) { return false }
                case .atMost: if !cardColors.isSubset(of: q.colors) { return false }
                }
            } else if q.colorless, !cardColors.isEmpty {
                return false
            }
            if let minColors = q.minColors, cardColors.count < minColors { return false }
            if let maxColors = q.maxColors, cardColors.count > maxColors { return false }
        }

        if let folded {
            if !typeTerms.matches(folded.typeLine) { return false }
            if !oracleTerms.matches(folded.oracleText) { return false }
        }

        if let wanted = wantedCost {
            let have = item.searchCache.manaSymbols(item)
            switch q.manaCostMatch {
            case .exactly: if wanted != have { return false }
            case .contains: if !CardSearchQuery.isSubMultiset(wanted, of: have) { return false }
            }
        }

        if !setCodes.isEmpty, !setCodes.contains(item.setCode.lowercased()) { return false }
        if !rarities.isEmpty, !rarities.contains(item.rarity.lowercased()) { return false }

        if q.price.isSet {
            guard let p = item.marketPrice else { return false }
            if let min = q.price.min, p < min { return false }
            if let max = q.price.max, p > max { return false }
        }

        for c in q.stats {
            let value: Int?
            switch c.stat {
            case .manaValue: value = item.searchCache.manaValue(item)
            case .power: value = Int(item.power ?? "")
            case .toughness: value = Int(item.toughness ?? "")
            case .loyalty: value = Int(item.loyalty ?? "")
            }
            guard let value, c.op.evaluate(value, c.value) else { return false }
        }

        if !q.finishes.isEmpty {
            let finish: CardFinishFilter
            switch item.finish {
            case .normal: finish = .nonfoil
            case .foil: finish = .foil
            case .etched: finish = .etched
            }
            if !q.finishes.contains(finish) { return false }
        }

        if let folded, !artist.isEmpty, !CardSearchFolding.contains(folded.artist, artist) { return false }
        return true
    }
}
