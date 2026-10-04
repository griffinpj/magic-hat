//
//  ManaBase.swift
//  magic-hat
//
//  The mana base, judged by arithmetic: for each colour the deck casts,
//  how many sources it has against how many it needs to cast its most
//  demanding early spell on time, in the manner of Frank Karsten's colour
//  tables. The target is worked out here rather than copied from a table,
//  with the same criterion his tables use — the number of sources at
//  which, in 90% of games where you made your land drops, you have the
//  coloured sources the spell wants on the turn you want to cast it —
//  as an exact nested hypergeometric over the cards seen by that turn:
//  the lands among them, and the sources among those lands. (The tables
//  come from a simulation with mulligans; this is the closed form of the
//  same question, and lands within a card or two of them.)
//
//  Also: the land count against Karsten's 2022 formula (lands = 31.42 +
//  3.13 × average mana value − 0.28 × cheap ramp and draw for a 99-card
//  deck; 19.59 + 1.90 × MV − 0.28 × cheap for 60), a basic split that
//  meets every colour's target with the basics the deck already runs,
//  and each land's weight — how much shorter a colour would be without
//  it. Pure, nonisolated, its own reading of the cards (basic types,
//  "Add" text, pips), shared with nothing else.
//

import Foundation

nonisolated struct ManaBaseReport: Hashable, Sendable {
    /// One colour the deck asks for.
    struct ColorLine: Identifiable, Hashable, Sendable {
        let color: ManaColor
        /// Pips of this colour across every cost.
        let pips: Int
        /// Lands and cheap producers that make it.
        let sources: Int
        /// Sources the most demanding early spell wants (see `target`).
        let target: Int
        /// That spell: its name, the pips of this colour in it, its mana
        /// value — "{G}{G} on turn 2".
        let demandName: String
        let demandPips: Int
        let demandTurn: Int
        /// P(having the sources for that spell on its turn) with the
        /// sources as they stand.
        let chance: Double
        var id: String { color.rawValue }
        var short: Int { max(0, target - sources) }
        var isShort: Bool { sources < target }
    }

    /// One non-basic land (or cheap producer) and what the deck loses
    /// without it.
    struct SourceLine: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let copies: Int
        let colors: [ManaColor]
        let anyColor: Bool
        let isBasic: Bool
        let isLand: Bool
        let entersTapped: Bool
        /// Colours that would fall short of their target without one copy.
        let holds: [ManaColor]
    }

    struct BasicSplit: Identifiable, Hashable, Sendable {
        let color: ManaColor
        let current: Int
        let suggested: Int
        var id: String { color.rawValue }
        var change: Int { suggested - current }
    }

    let deckSize: Int
    let lands: Int
    /// Non-land permanents that add mana for two or less.
    let cheapProducers: Int
    let averageManaValue: Double
    /// Spells of mana value two or less that draw or make mana — what the
    /// land formula subtracts for.
    let cheapRampAndDraw: Int
    /// Karsten's land count for this curve, rounded.
    let suggestedLands: Int
    let colors: [ColorLine]
    let sources: [SourceLine]
    let basics: [BasicSplit]
    /// Share of the lands that enter untapped.
    let untappedShare: Double

    var shortColors: [ColorLine] { colors.filter(\.isShort) }
    var basicsChange: Bool { basics.contains { $0.change != 0 } }
}

nonisolated enum ManaBase {
    /// The probability a colour's sources must reach on the spell's turn.
    static let confidence = 0.90

    /// A card as the mana base sees it.
    struct Reading: Hashable, Sendable {
        let name: String
        let isLand: Bool
        let isBasic: Bool
        let entersTapped: Bool
        let produces: Set<ManaColor>
        let anyColor: Bool
        let manaValue: Int
        /// Pips by colour (a hybrid pip counts for each of its colours).
        let pips: [ManaColor: Int]
        let isCheapProducer: Bool
        let isCheapDraw: Bool

        private static let addGroup = try! NSRegularExpression(pattern: #"add ((?:\{[wubrgc]\}(?:, | or | and/or | and )?)+)"#)
        private static let anyColorText = try! NSRegularExpression(pattern: #"mana of any (?:one )?colou?r|any combination of colou?rs"#)
        private static let tapped = try! NSRegularExpression(pattern: #"enters (?:the battlefield )?tapped(?! unless)"#)
        private static let draw = try! NSRegularExpression(pattern: #"draw (?:a|two|three) cards?"#)

        init(_ card: CardItem) {
            let type = card.typeLine ?? ""
            let front = type.components(separatedBy: " // ").first ?? type
            let text = (card.oracleText ?? "").lowercased()
            let whole = NSRange(text.startIndex..., in: text)
            name = card.name
            isLand = front.contains("Land")
            isBasic = type.hasPrefix("Basic ")
            entersTapped = Self.tapped.firstMatch(in: text, range: whole) != nil
            let cost = (card.manaCost ?? "").components(separatedBy: " // ").first ?? ""
            manaValue = isLand ? 0 : ManaSymbol.manaValue(of: cost)

            var produces = Set<ManaColor>()
            let basics: [(String, ManaColor)] = [("Plains", .white), ("Island", .blue), ("Swamp", .black), ("Mountain", .red), ("Forest", .green)]
            for (basic, color) in basics where front.contains(basic) { produces.insert(color) }
            var any = false
            let permanent = isLand || front.contains("Artifact") || front.contains("Creature") || front.contains("Enchantment")
            if permanent, text.contains("add ") {
                for m in Self.addGroup.matches(in: text, range: whole) {
                    guard let r = Range(m.range(at: 1), in: text) else { continue }
                    for symbol in ManaSymbol.parse(String(text[r])) { for color in symbol.colors { produces.insert(color) } }
                }
                if Self.anyColorText.firstMatch(in: text, range: whole) != nil { any = true }
            }
            self.produces = produces
            anyColor = any
            isCheapProducer = !isLand && permanent && (any || !produces.isEmpty || (text.contains("add {c}"))) && manaValue <= 2
            isCheapDraw = !isLand && manaValue <= 2 && Self.draw.firstMatch(in: text, range: whole) != nil

            var pips: [ManaColor: Int] = [:]
            for symbol in ManaSymbol.parse(cost) where !symbol.isPhyrexian {
                if symbol.parts.first.flatMap(Int.init) != nil { continue }
                for color in symbol.colors { pips[color, default: 0] += 1 }
            }
            self.pips = pips
        }

        func makes(_ color: ManaColor, identity: Set<ManaColor>) -> Bool {
            produces.contains(color) || (anyColor && identity.contains(color))
        }
    }

    /// Reads the played boards and judges the mana base.
    static func report(snapshot: DeckSnapshot) -> ManaBaseReport {
        let played = snapshot.sections.flatMap(\.items)
        let readings = played.map { (Reading($0.card), max(0, $0.quantity)) }
        let identity = Set(snapshot.identity.isEmpty ? Array(ManaColor.allCases) : snapshot.identity)
        return report(readings: readings, commanders: snapshot.commanders.map { Reading($0.card) },
                      identity: identity, format: snapshot.format)
    }

    static func report(readings: [(Reading, Int)], commanders: [Reading] = [], identity: Set<ManaColor>, format: DeckFormat) -> ManaBaseReport {
        let deckSize = readings.reduce(0) { $0 + $1.1 }
        let lands = readings.filter { $0.0.isLand }.reduce(0) { $0 + $1.1 }
        let cheapProducers = readings.filter { $0.0.isCheapProducer }.reduce(0) { $0 + $1.1 }
        let spells = readings.filter { !$0.0.isLand }
        let spellCopies = spells.reduce(0) { $0 + $1.1 }
        let averageMV = spellCopies > 0 ? Double(spells.reduce(0) { $0 + $1.0.manaValue * $1.1 }) / Double(spellCopies) : 0
        let cheap = readings.filter { $0.0.isCheapProducer || $0.0.isCheapDraw }.reduce(0) { $0 + $1.1 }
        let suggestedLands = Self.suggestedLands(deckSize: deckSize + commanders.count, averageManaValue: averageMV, cheap: cheap, format: format)

        // Sources per colour: lands and cheap producers.
        let pool = readings.filter { $0.0.isLand || $0.0.isCheapProducer }
        let poolSize = pool.reduce(0) { $0 + $1.1 }
        func sources(_ color: ManaColor, without excluded: Reading? = nil) -> Int {
            pool.reduce(0) { acc, entry in
                guard entry.0.makes(color, identity: identity) else { return acc }
                if let excluded, entry.0 == excluded { return acc + max(0, entry.1 - 1) }
                return acc + entry.1
            }
        }

        // The demand per colour: the spell (commanders included) whose
        // pips of that colour on its turn need the most sources.
        var lines: [ManaBaseReport.ColorLine] = []
        let allSpells = spells.map(\.0) + commanders
        for color in ManaColor.allCases {
            var pipTotal = 0
            for (spell, copies) in spells { pipTotal += (spell.pips[color] ?? 0) * copies }
            for commander in commanders { pipTotal += commander.pips[color] ?? 0 }
            guard pipTotal > 0 else { continue }
            var best: (name: String, pips: Int, turn: Int, target: Int)?
            for spell in allSpells {
                guard let p = spell.pips[color], p > 0 else { continue }
                let turn = max(spell.manaValue, p, 1)
                let target = sourcesNeeded(pips: p, turn: turn, deckSize: deckSize, pool: poolSize)
                if best == nil || target > best!.target { best = (spell.name, p, turn, target) }
            }
            guard let best else { continue }
            let have = sources(color)
            let chance = chanceOfSources(have, pips: best.pips, turn: best.turn, deckSize: deckSize, pool: poolSize)
            lines.append(ManaBaseReport.ColorLine(color: color, pips: pipTotal, sources: have, target: best.target,
                                                  demandName: best.name, demandPips: best.pips, demandTurn: best.turn, chance: chance))
        }
        let targets = Dictionary(uniqueKeysWithValues: lines.map { ($0.color, $0.target) })

        // Each non-basic source's weight: the colours that fall short
        // without one copy. Basics are the split above.
        var sourceLines: [ManaBaseReport.SourceLine] = []
        var seen = Set<String>()
        for (reading, copies) in pool where copies > 0 && !reading.isBasic && !seen.contains(reading.name) {
            seen.insert(reading.name)
            let colors = ManaColor.allCases.filter { reading.makes($0, identity: identity) }
            let holds = colors.filter { color in
                guard let target = targets[color] else { return false }
                return sources(color, without: reading) < target && sources(color) >= target
            }
            sourceLines.append(ManaBaseReport.SourceLine(
                id: reading.name, name: reading.name, copies: copies, colors: colors,
                anyColor: reading.anyColor, isBasic: reading.isBasic, isLand: reading.isLand,
                entersTapped: reading.entersTapped, holds: holds))
        }
        sourceLines.sort { a, b in
            if a.holds.isEmpty != b.holds.isEmpty { return !a.holds.isEmpty }
            if a.isLand != b.isLand { return a.isLand }
            return a.name < b.name
        }

        // Basics: the same number of them, split so every colour reaches
        // its target if it can, the rest by pip share.
        let basicCount = readings.filter { $0.0.isBasic }.reduce(0) { $0 + $1.1 }
        var current: [ManaColor: Int] = [:]
        for (reading, copies) in readings where reading.isBasic {
            for color in reading.produces { current[color, default: 0] += copies }
        }
        let nonbasic: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: lines.map { line in
            (line.color, pool.reduce(0) { acc, entry in
                guard !entry.0.isBasic, entry.0.makes(line.color, identity: identity) else { return acc }
                return acc + entry.1
            })
        })
        var split: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: lines.map { ($0.color, 0) })
        let pipTotal = Double(max(1, lines.reduce(0) { $0 + $1.pips }))
        // The colour furthest below its target, relative to it; past the
        // targets, the colour furthest below its pip share.
        func need(_ line: ManaBaseReport.ColorLine) -> Double {
            let have = (nonbasic[line.color] ?? 0) + (split[line.color] ?? 0)
            if have < line.target { return 1 + Double(line.target - have) / Double(line.target) }
            let share = Double(line.pips) / pipTotal
            let assigned = Double(split[line.color] ?? 0) / Double(max(1, basicCount))
            return share - assigned
        }
        for _ in 0..<basicCount where !lines.isEmpty {
            let pick = lines.max { a, b in need(a) < need(b) }!
            split[pick.color, default: 0] += 1
        }
        // Every basic the deck runs, and every colour the split gives one:
        // a colour with basics and no pips shows its basics going to zero.
        let basics = ManaColor.allCases.compactMap { color -> ManaBaseReport.BasicSplit? in
            let now = current[color] ?? 0, then = split[color] ?? 0
            guard now > 0 || then > 0 else { return nil }
            return ManaBaseReport.BasicSplit(color: color, current: now, suggested: then)
        }

        let untapped = readings.filter { $0.0.isLand && !$0.0.entersTapped }.reduce(0) { $0 + $1.1 }
        return ManaBaseReport(
            deckSize: deckSize, lands: lands, cheapProducers: cheapProducers, averageManaValue: averageMV,
            cheapRampAndDraw: cheap, suggestedLands: suggestedLands, colors: lines, sources: sourceLines,
            basics: basics, untappedShare: lands > 0 ? Double(untapped) / Double(lands) : 0)
    }

    // MARK: The maths

    /// Cards seen by the start of `turn` on the draw: seven and one a turn.
    static func cardsSeen(byTurn turn: Int) -> Int { 7 + max(0, turn - 1) }

    /// P(at least `pips` sources of a colour among the pool cards drawn by
    /// `turn`, given at least `turn` pool cards were drawn — that is, in the
    /// games where the land drops were made).
    static func chanceOfSources(_ sources: Int, pips: Int, turn: Int, deckSize: Int, pool: Int) -> Double {
        guard deckSize > 0, pool > 0, sources >= 0 else { return 0 }
        let seen = min(deckSize, cardsSeen(byTurn: turn))
        let needLands = min(turn, pool)
        var hit = 0.0, made = 0.0
        for drawnPool in needLands...min(seen, pool) {
            let pDrawn = Hypergeometric.exactly(drawnPool, population: deckSize, successes: pool, draws: seen)
            guard pDrawn > 0 else { continue }
            made += pDrawn
            hit += pDrawn * Hypergeometric.atLeast(pips, population: pool, successes: min(sources, pool), draws: drawnPool)
        }
        return made > 0 ? hit / made : 0
    }

    /// The fewest sources at which `chanceOfSources` reaches `confidence`.
    static func sourcesNeeded(pips: Int, turn: Int, deckSize: Int, pool: Int) -> Int {
        guard pool > 0 else { return 0 }
        for sources in 1...pool where chanceOfSources(sources, pips: pips, turn: turn, deckSize: deckSize, pool: pool) >= confidence {
            return sources
        }
        return pool
    }

    /// Karsten's 2022 land count for the curve, scaled to the deck size.
    static func suggestedLands(deckSize: Int, averageManaValue: Double, cheap: Int, format: DeckFormat) -> Int {
        let lands: Double
        if format.hasCommander || deckSize >= 90 {
            lands = 31.42 + 3.13 * averageManaValue - 0.28 * Double(cheap)
        } else {
            let sixty = 19.59 + 1.90 * averageManaValue - 0.28 * Double(cheap)
            lands = deckSize > 0 && deckSize != 60 ? sixty * Double(deckSize) / 60 : sixty
        }
        return max(0, Int(lands.rounded()))
    }
}
