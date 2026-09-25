//
//  CardReason.swift
//  magic-hat
//
//  Why a card is being shown next to another card or a deck, in one
//  standard line: a kind (which picks the icon and the tint) and a short
//  phrase in a fixed vocabulary. The recommendations, the swap table and
//  the Synergies screen all speak it, so a row reads the same wherever it
//  is — "Combo with X", "Ramp, 7 of 8", "On plan: tokens", "+82% synergy"
//  — rather than each source's own sentence.
//

import Foundation

nonisolated struct CardReason: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        /// Completes, or is part of, a combo.
        case combo
        /// Fills a composition floor the deck is under.
        case gap
        /// Adds a colour source the mana base is short of.
        case source
        /// Touches a mechanic the commander pays off.
        case plan
        /// The meta plays it with this commander (Recommander).
        case meta
        /// Played with the card far beyond chance (EDHREC).
        case synergy
        /// Its text touches the same theme.
        case theme
        /// Widely played (EDHREC rank).
        case popular
        /// The cut side: no role, off plan, the weakest of the list.
        case weak
        /// A rule the row breaks: outside the identity, an extra copy.
        case rule
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var systemImage: String {
        switch kind {
        case .combo: return "link"
        case .gap: return "arrow.up.right"
        case .source: return "paintpalette"
        case .plan: return "target"
        case .meta: return "chart.bar"
        case .synergy: return "sparkles"
        case .theme: return "tag"
        case .popular: return "star"
        case .weak: return "minus.circle"
        case .rule: return "exclamationmark.triangle"
        }
    }

    // MARK: The vocabulary

    /// "Combo with A + B": the other pieces, at most two named.
    static func combo(with pieces: [String]) -> CardReason {
        let named = pieces.prefix(2).joined(separator: " + ")
        return CardReason(.combo, named.isEmpty ? "Combo piece" : "Combo with " + named + (pieces.count > 2 ? " +" : ""))
    }

    /// "Infinite mana": what a combo makes, from Spellbook's feature name.
    static func comboResult(_ produces: String?) -> CardReason {
        guard let produces, !produces.isEmpty else { return CardReason(.combo, "Combo piece") }
        return CardReason(.combo, produces.prefix(1).uppercased() + produces.dropFirst())
    }

    static func inCombos(_ n: Int) -> CardReason {
        CardReason(.combo, n == 1 ? "Combo piece" : "In \(n) combos")
    }

    /// "Ramp, 7 of 8".
    static func gap(_ role: CardRole, have: Int) -> CardReason {
        CardReason(.gap, "\(role.label), \(have) of \(role.floor)")
    }

    /// "White source".
    static func source(_ color: ManaColor) -> CardReason {
        CardReason(.source, "\(color.name) source")
    }

    /// "Tokens" — the mechanic the commander pays off; the icon says "on
    /// plan", so the phrase is just the mechanic and fits a narrow row.
    static func plan(_ label: String) -> CardReason {
        CardReason(.plan, label.prefix(1).uppercased() + label.dropFirst())
    }

    /// "Meta 82%".
    static func meta(_ score: Double) -> CardReason {
        CardReason(.meta, "Meta \(Int((score * 100).rounded()))%")
    }

    /// "+82% synergy" (a commander page: EDHREC's synergy, a share above
    /// the card's baseline) or "79× as often" (a card page: `lift` − 1,
    /// how many times more often than chance the two are played together —
    /// a ratio, not a share; the real pages run past 70, and "+7827%"
    /// said nothing).
    static func synergy(_ score: Double, commander: Bool) -> CardReason {
        if commander {
            let pct = Int((score * 100).rounded())
            return CardReason(.synergy, (pct >= 0 ? "+" : "") + "\(pct)% synergy")
        }
        let lift = score + 1
        let times = lift < 10 ? String(format: "%.1f", lift) : String(format: "%.0f", lift)
        return CardReason(.synergy, "\(times.hasSuffix(".0") ? String(times.dropLast(2)) : times)× as often")
    }

    /// "Lifegain".
    static func theme(_ label: String) -> CardReason {
        CardReason(.theme, label.prefix(1).uppercased() + label.dropFirst())
    }

    static let popular = CardReason(.popular, "Widely played")
    static let noRole = CardReason(.weak, "No role")
    static let offPlan = CardReason(.weak, "Off plan")
    static let weakest = CardReason(.weak, "Weakest of the list")
    static let outsideIdentity = CardReason(.rule, "Outside identity")
    static func extraCopies(_ n: Int) -> CardReason { CardReason(.rule, n == 1 ? "Extra copy" : "\(n) extra copies") }
}
