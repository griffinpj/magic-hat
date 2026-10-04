//
//  Hypergeometric.swift
//  magic-hat
//
//  Draw odds, exactly. A deck is an urn: N cards, K of them the ones you
//  want, n drawn without replacement. The hypergeometric distribution says
//  how likely k of the n are wanted ones — the maths behind "how often is
//  a land in my opening hand" and "will I see this by turn four". Pure
//  and nonisolated: the Odds screen computes a whole deck's table off the
//  main actor, and tests check it against known values.
//
//  Nothing here reads card text. `DrawOdds` turns a deck's played cards
//  into rows (copies per name, the lands as a group) and the screen asks
//  it for probabilities by turn.
//

import Foundation

nonisolated enum Hypergeometric {
    /// ln(C(n, k)), through lgamma so a 99-card deck never overflows.
    static func logChoose(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return -.infinity }
        return lgamma(Double(n) + 1) - lgamma(Double(k) + 1) - lgamma(Double(n - k) + 1)
    }

    /// P(exactly `hits` wanted cards among `draws` from `population` with
    /// `successes` wanted ones).
    static func exactly(_ hits: Int, population: Int, successes: Int, draws: Int) -> Double {
        guard population > 0, draws >= 0, draws <= population, successes >= 0, successes <= population else { return 0 }
        guard hits >= 0, hits <= successes, hits <= draws, draws - hits <= population - successes else { return 0 }
        let log = logChoose(successes, hits) + logChoose(population - successes, draws - hits) - logChoose(population, draws)
        return exp(log)
    }

    /// P(at least `hits`).
    static func atLeast(_ hits: Int, population: Int, successes: Int, draws: Int) -> Double {
        guard hits > 0 else { return 1 }
        let top = min(successes, draws)
        guard hits <= top else { return 0 }
        var total = 0.0
        for k in hits...top { total += exactly(k, population: population, successes: successes, draws: draws) }
        return min(1, total)
    }

    /// P(at most `hits`).
    static func atMost(_ hits: Int, population: Int, successes: Int, draws: Int) -> Double {
        1 - atLeast(hits + 1, population: population, successes: successes, draws: draws)
    }

    /// The whole distribution 0…min(successes, draws), as an array by count.
    static func distribution(population: Int, successes: Int, draws: Int) -> [Double] {
        let top = max(0, min(successes, draws))
        return (0...top).map { exactly($0, population: population, successes: successes, draws: draws) }
    }
}

/// The deck as draws: how many cards are seen by a turn, and the odds of
/// a named card or a group by then.
nonisolated struct DrawOdds: Hashable, Sendable {
    /// One row of the table: a card (or a group such as the lands) and
    /// how many of the library it is.
    struct Row: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let copies: Int
        /// The lands as one row, or any one card.
        let isGroup: Bool
        let imageURL: String?
    }

    static let openingHand = 7

    /// Library size: the played mainboard. Commanders start in the command
    /// zone and are never drawn.
    let librarySize: Int
    let rows: [Row]

    init(librarySize: Int, rows: [Row]) {
        self.librarySize = librarySize
        self.rows = rows
    }

    /// From the deck's mainboard: one row per card name (copies summed
    /// across printings), the lands as a group first.
    init(snapshot: DeckSnapshot) {
        var copies: [String: Int] = [:]
        var order: [String] = []
        var images: [String: String] = [:]
        var lands = 0
        var total = 0
        for item in snapshot.sections.flatMap(\.items) {
            let qty = max(0, item.quantity)
            total += qty
            let name = item.card.name
            if copies[name] == nil { order.append(name) }
            copies[name, default: 0] += qty
            if images[name] == nil, let url = item.card.imageURL { images[name] = url }
            if (item.card.typeLine ?? "").contains("Land") { lands += qty }
        }
        var rows: [Row] = []
        if lands > 0 { rows.append(Row(id: "group:lands", name: "Any land", copies: lands, isGroup: true, imageURL: nil)) }
        rows += order.map { Row(id: "card:" + $0, name: $0, copies: copies[$0] ?? 0, isGroup: false, imageURL: images[$0]) }
        self.init(librarySize: total, rows: rows)
    }

    /// Cards seen by the start of turn `turn`: the opening seven, then one
    /// a turn — the player on the play skips their first draw.
    static func cardsSeen(byTurn turn: Int, onThePlay: Bool) -> Int {
        guard turn >= 1 else { return openingHand }
        return openingHand + turn - (onThePlay ? 1 : 0)
    }

    /// P(at least `atLeast` of `copies` among the cards seen by `turn`).
    func chance(copies: Int, atLeast: Int = 1, byTurn turn: Int, onThePlay: Bool) -> Double {
        let seen = min(librarySize, Self.cardsSeen(byTurn: turn, onThePlay: onThePlay))
        return Hypergeometric.atLeast(atLeast, population: librarySize, successes: copies, draws: seen)
    }

    /// P(at least `atLeast` of `copies` in the opening seven).
    func openingChance(copies: Int, atLeast: Int = 1) -> Double {
        Hypergeometric.atLeast(atLeast, population: librarySize, successes: copies, draws: min(librarySize, Self.openingHand))
    }

    /// How the opening seven split for a group: index k is P(exactly k).
    func openingDistribution(copies: Int) -> [Double] {
        Hypergeometric.distribution(population: librarySize, successes: copies, draws: min(librarySize, Self.openingHand))
    }

    /// P(at least one of any of `rows`' cards by `turn`): the rows' copies
    /// pooled, since each is a distinct card.
    func chanceOfAny(_ rows: [Row], byTurn turn: Int, onThePlay: Bool) -> Double {
        let pooled = rows.reduce(0) { $0 + $1.copies }
        return chance(copies: min(pooled, librarySize), byTurn: turn, onThePlay: onThePlay)
    }

    /// P(every one of `rows` is seen by `turn`) — the chance of having
    /// all the pieces, not just one. Exact by inclusion–exclusion over the
    /// rows (the events "row i is missing" are what the hypergeometric
    /// gives directly); the screen caps the selection so it stays small.
    func chanceOfAll(_ rows: [Row], byTurn turn: Int, onThePlay: Bool) -> Double {
        guard !rows.isEmpty else { return 1 }
        let seen = min(librarySize, Self.cardsSeen(byTurn: turn, onThePlay: onThePlay))
        let n = rows.count
        var total = 0.0
        // Σ over subsets S of (−1)^|S| P(none of S seen): P(none of S) is
        // P(0 of the pooled copies of S in `seen`).
        for mask in 0..<(1 << n) {
            var pooled = 0
            var bits = 0
            for i in 0..<n where mask & (1 << i) != 0 { pooled += rows[i].copies; bits += 1 }
            let none = Hypergeometric.exactly(0, population: librarySize, successes: min(pooled, librarySize), draws: seen)
            total += (bits % 2 == 0 ? 1 : -1) * none
        }
        return min(1, max(0, total))
    }
}
