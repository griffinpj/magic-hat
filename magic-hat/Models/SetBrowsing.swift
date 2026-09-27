//
//  SetBrowsing.swift
//  magic-hat
//
//  The Search tab's Sets page as plain values: which kinds of set to show
//  (Scryfall's `set_type`, folded into the groups a player thinks in), the
//  name filter, and the sections by year, newest first. Pure, so it runs
//  off the main actor and under test.
//

import Foundation

nonisolated enum SetKind: String, CaseIterable, Identifiable, Sendable {
    case main, masters, commander, supplemental, promos, tokens, all

    var id: String { rawValue }
    var label: String {
        switch self {
        case .main: return "Main Sets"
        case .masters: return "Masters & Remasters"
        case .commander: return "Commander"
        case .supplemental: return "Supplemental"
        case .promos: return "Promos"
        case .tokens: return "Tokens"
        case .all: return "All Sets"
        }
    }

    func includes(_ type: String?) -> Bool {
        let t = type ?? ""
        switch self {
        case .main: return ["expansion", "core", "draft_innovation"].contains(t)
        case .masters: return ["masters", "eternal", "masterpiece", "from_the_vault", "spellbook"].contains(t)
        case .commander: return t == "commander"
        case .supplemental: return ["box", "duel_deck", "premium_deck", "planechase", "archenemy", "funny", "starter",
                                    "arsenal", "treasure_chest", "minigame", "vanguard"].contains(t)
        case .promos: return ["promo", "memorabilia"].contains(t)
        case .tokens: return t == "token"
        case .all: return true
        }
    }
}

nonisolated struct SetSection: Identifiable, Hashable, Sendable {
    let year: String
    let sets: [ScryfallSet]
    var id: String { year }
}

nonisolated enum SetBrowsing {
    /// Sets of `kind` matching `filter` (name or code), paper unless
    /// `digital`, by release year, newest first; within a year newest first.
    static func sections(_ sets: [ScryfallSet], kind: SetKind, filter: String, digital: Bool) -> [SetSection] {
        let needle = filter.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let shown = sets.filter { set in
            guard kind.includes(set.setType), digital || set.digital != true else { return false }
            guard !needle.isEmpty else { return true }
            let name = (set.name ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return name.contains(needle) || set.code.lowercased().hasPrefix(needle)
        }
        let byYear = Dictionary(grouping: shown) { $0.releasedAt.map { String($0.prefix(4)) } ?? "Unreleased" }
        return byYear.keys.sorted(by: >).map { year in
            SetSection(year: year, sets: byYear[year]!.sorted { a, b in
                if (a.releasedAt ?? "") != (b.releasedAt ?? "") { return (a.releasedAt ?? "") > (b.releasedAt ?? "") }
                return a.code < b.code
            })
        }
    }

    /// "Sep 26, 2026" from Scryfall's "2026-09-26".
    static func releaseDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
