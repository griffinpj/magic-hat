//
//  Goldfish.swift
//  magic-hat
//
//  A Monte Carlo goldfish: the deck played against nobody, thousands of
//  times, by a simple honest player — Frank Karsten's method for land
//  counts and colour sources, applied to this list. Each game: shuffle,
//  seven, a London mulligan on a land-count rule, then turn by turn: draw,
//  play the land that helps most, cast what the mana allows (ramp first,
//  then the commander, then the biggest spell that fits), count. The
//  result is not a win rate — there is no opponent and no combat — but
//  the things a deck does on its own that decide games: hitting land
//  drops, having the colours, spending its mana, casting its commander on
//  time.
//
//  The player reads a card from its type line, cost and rules text with a
//  few patterns (`GoldfishCard`): what it adds, whether it enters tapped,
//  whether it fetches a land or draws. That is deliberately shallow — a
//  table that keeps count, like the playtest screen — and shared with
//  nothing else in the app, so it can be read and tested on its own.
//
//  Pure and nonisolated; the screen runs it `@concurrent`. Seeded (the
//  same SplitMix64 as the playtest), so `GoldfishTests` get the same
//  numbers every run.
//

import Foundation

/// One card as the goldfish player sees it.
nonisolated struct GoldfishCard: Hashable, Sendable {
    let name: String
    let isLand: Bool
    let isBasic: Bool
    let entersTapped: Bool
    /// Colours each unit of its mana can be (bit per `ManaColor`, in
    /// `allCases` order); 0 is colourless-only. Empty producer: amount 0.
    let produces: UInt8
    /// Units added per turn once it is on the battlefield and untapped.
    let manaAmount: Int
    /// A creature's mana waits a turn (summoning sickness).
    let isCreatureProducer: Bool
    /// Lands it puts onto the battlefield from the library when cast.
    let fetchesLands: Int
    let fetchedTapped: Bool
    /// Cards it draws when cast or when it enters.
    let draws: Int
    /// Coloured pips of the cost, each a mask of the colours that pay it
    /// (a hybrid pip has two bits).
    let pips: [UInt8]
    let generic: Int
    let manaValue: Int
    let isCommander: Bool

    var isSpell: Bool { !isLand }
    var isProducer: Bool { manaAmount > 0 }
    /// Ramp in the player's sense: a spell that makes mana or fetches land.
    var isRamp: Bool { isSpell && (isProducer || fetchesLands > 0) }

    static func bit(_ color: ManaColor) -> UInt8 {
        UInt8(1 << (ManaColor.allCases.firstIndex(of: color) ?? 0))
    }
    static let anyColor: UInt8 = 0b11111

    private static let tapped = try! NSRegularExpression(pattern: #"enters (?:the battlefield )?tapped"#)
    private static let unless = try! NSRegularExpression(pattern: #"enters (?:the battlefield )?tapped unless|you may have .* enter tapped|if you do, .* enters tapped"#)
    private static let addGroup = try! NSRegularExpression(pattern: #"add ((?:\{[wubrgc]\}(?:, | or | and/or | and )?)+)"#)
    private static let activationCost = try! NSRegularExpression(pattern: #"\{(\d)\}, \{t\}: add"#)
    private static let addWords = try! NSRegularExpression(pattern: #"add (one|two|three) mana"#)
    private static let anyColorText = try! NSRegularExpression(pattern: #"mana of any (?:one )?colou?r|any combination of colou?rs"#)
    private static let fetch = try! NSRegularExpression(pattern: #"search your library for ((?:up to )?(?:a|an|one|two|three) )?[^.]*?\b(?:land|plains|island|swamp|mountain|forest)s? cards?[^.]*?onto the battlefield( tapped)?"#)
    private static let drawText = try! NSRegularExpression(pattern: #"draw (a|two|three|four) cards?"#)

    init(_ card: CardItem, isCommander: Bool = false) {
        let type = card.typeLine ?? ""
        let text = (card.oracleText ?? "").lowercased()
        name = card.name
        self.isCommander = isCommander
        let front = type.components(separatedBy: " // ").first ?? type
        isLand = front.contains("Land")
        isBasic = type.hasPrefix("Basic ")

        // Enters tapped: a plain "enters tapped" that no clause lets you avoid.
        let whole = NSRange(text.startIndex..., in: text)
        entersTapped = Self.tapped.firstMatch(in: text, range: whole) != nil
            && Self.unless.firstMatch(in: text, range: whole) == nil

        // What it adds.
        var mask: UInt8 = 0
        var amount = 0
        let basics: [(String, ManaColor)] = [("Plains", .white), ("Island", .blue), ("Swamp", .black), ("Mountain", .red), ("Forest", .green)]
        for (basic, color) in basics where front.contains(basic) { mask |= Self.bit(color); amount = max(amount, 1) }
        let canProduce = isLand || front.contains("Artifact") || front.contains("Creature") || front.contains("Enchantment")
        if canProduce, text.contains("add ") {
            if let m = Self.addGroup.firstMatch(in: text, range: whole), let r = Range(m.range(at: 1), in: text) {
                let group = String(text[r])
                var units = 0
                for symbol in ManaSymbol.parse(group) {
                    units += 1
                    for color in symbol.colors { mask |= Self.bit(color) }
                }
                // "{G} or {U}" is one mana of either; "{W}{U}" is two.
                if group.contains(" or ") || group.contains(", ") { units = 1 }
                // A Signet pays one to make two: net one.
                if let cost = Self.activationCost.firstMatch(in: text, range: whole), let cr = Range(cost.range(at: 1), in: text),
                   let paid = Int(text[cr]) { units = max(1, units - paid) }
                amount = max(amount, units)
            }
            if let m = Self.addWords.firstMatch(in: text, range: whole), let r = Range(m.range(at: 1), in: text) {
                amount = max(amount, ["one": 1, "two": 2, "three": 3][String(text[r])] ?? 1)
            }
            if Self.anyColorText.firstMatch(in: text, range: whole) != nil {
                mask = Self.anyColor
                amount = max(amount, 1)
            }
        }
        // An Add on a land with no basic type and no symbol read (an
        // "any colour" land handled above, a filter land) still taps for one.
        if isLand, amount == 0, text.contains("add ") { amount = 1 }
        produces = mask
        manaAmount = amount
        isCreatureProducer = amount > 0 && !isLand && front.contains("Creature")

        // Land fetch spells and creatures: Rampant Growth, Three Visits,
        // Cultivate (one of its two to the battlefield), Wood Elves.
        if !isLand, let m = Self.fetch.firstMatch(in: text, range: whole) {
            var n = 1
            if let r = Range(m.range(at: 1), in: text) {
                let words = String(text[r])
                if words.contains("two") { n = 2 } else if words.contains("three") { n = 3 }
            }
            fetchesLands = n
            fetchedTapped = m.range(at: 2).location != NSNotFound
        } else {
            fetchesLands = 0
            fetchedTapped = false
        }

        // A draw the player gets on casting: not a repeating trigger.
        var draws = 0
        if !isLand, let m = Self.drawText.firstMatch(in: text, range: whole), let r = Range(m.range(at: 1), in: text) {
            let sentenceStart = text[..<r.lowerBound].lastIndex(of: ".").map { text.index(after: $0) } ?? text.startIndex
            let sentence = text[sentenceStart..<r.upperBound]
            if !sentence.contains("whenever"), !sentence.contains("at the beginning"), !sentence.contains("each upkeep") {
                draws = ["a": 1, "two": 2, "three": 3, "four": 4][String(text[r])] ?? 1
            }
        }
        self.draws = draws

        // The cost: the front face's.
        let cost = (card.manaCost ?? "").components(separatedBy: " // ").first ?? ""
        var pips: [UInt8] = []
        var generic = 0
        for symbol in ManaSymbol.parse(cost) {
            if let n = Int(symbol.raw) { generic += n; continue }
            if symbol.isPhyrexian { continue }                   // payable with life
            if let first = symbol.parts.first, let n = Int(first) { generic += n; continue }   // {2/W} as 2
            let colors = symbol.colors
            if colors.isEmpty {
                if symbol.raw.uppercased() == "C" || symbol.raw.uppercased() == "S" { generic += 1 }
                continue                                         // X, Y: zero
            }
            pips.append(colors.reduce(0) { $0 | Self.bit($1) })
        }
        self.pips = pips
        self.generic = generic
        manaValue = isLand ? 0 : ManaSymbol.manaValue(of: cost)
    }
}

nonisolated struct GoldfishConfig: Hashable, Sendable {
    var games = 5_000
    var turns = 8
    var onThePlay = true
    /// Keep a seven with this many lands; otherwise mulligan, up to
    /// `maxMulligans` times (London: seven again, one more to the bottom).
    var minLands = 2
    var maxLands = 5
    var maxMulligans = 2
    var seed: UInt64 = 0x600D_F15E

    init() {}
}

/// What thousands of games add up to. Every per-turn array is indexed by
/// turn, so `[0]` is unused and `[t]` is turn t.
nonisolated struct GoldfishResult: Hashable, Sendable {
    let games: Int
    let turns: Int
    let onThePlay: Bool
    /// P(a land was played on turn t).
    let landDrop: [Double]
    /// P(a land was played on every turn through t).
    let everyLandDrop: [Double]
    /// Mean lands on the battlefield at the end of turn t.
    let lands: [Double]
    /// Mean mana the battlefield could make on turn t.
    let manaAvailable: [Double]
    /// Mean mana spent on turn t.
    let manaSpent: [Double]
    /// Mean spells cast through turn t.
    let spellsCast: [Double]
    /// P(on turn t a spell in hand fit the mana count but not its colours).
    let colorStuck: [Double]
    /// P(that happened on some turn through t).
    let colorStuckBy: [Double]
    /// P(the commander was cast by the end of turn t); empty without one.
    let commanderCastBy: [Double]
    /// Mean turn the commander was first cast, over games it was.
    let commanderMeanTurn: Double?
    /// Share of games by mulligans taken: index 0 is no mulligan.
    let mulligans: [Double]
    /// Share of games by lands in the kept hand, 0…7.
    let keptLands: [Double]
    /// Mean cards left in hand after the last turn that could not have been
    /// cast with the battlefield as it stood.
    let deadCardsAtEnd: Double
    /// Mean cards in hand at the end of turn t.
    let handSize: [Double]

    /// Mana spent over mana available, turns 1…t pooled.
    var efficiency: Double {
        let spent = manaSpent.dropFirst().reduce(0, +)
        let available = manaAvailable.dropFirst().reduce(0, +)
        return available > 0 ? spent / available : 0
    }
}

nonisolated enum Goldfish {
    /// The deck's played boards as the player sees them: every mainboard
    /// copy in the library, commanders in the command zone.
    static func cards(from snapshot: DeckSnapshot) -> [GoldfishCard] {
        var cards: [GoldfishCard] = []
        for item in snapshot.commanders { cards.append(GoldfishCard(item.card, isCommander: true)) }
        for item in snapshot.sections.flatMap(\.items) {
            let card = GoldfishCard(item.card)
            for _ in 0..<max(0, item.quantity) { cards.append(card) }
        }
        return cards
    }

    /// Plays `config.games` games of `cards` and adds them up.
    static func run(_ cards: [GoldfishCard], config: GoldfishConfig) -> GoldfishResult {
        var rng = SeededGenerator(seed: config.seed)
        return run(cards, config: config, using: &rng)
    }

    static func run<G: RandomNumberGenerator>(_ cards: [GoldfishCard], config: GoldfishConfig, using rng: inout G) -> GoldfishResult {
        let turns = max(1, config.turns)
        let games = max(1, config.games)
        let deck = Deck(cards: cards)
        var tally = Tally(turns: turns, hasCommander: !deck.commanders.isEmpty)
        for _ in 0..<games {
            var game = Game(deck: deck, config: config)
            game.play(using: &rng, tally: &tally)
        }
        return tally.result(games: games, turns: turns, onThePlay: config.onThePlay)
    }

    // MARK: The table

    /// The cards split once: library indices and the commanders.
    private struct Deck {
        let cards: [GoldfishCard]
        let library: [Int]
        let commanders: [Int]

        init(cards: [GoldfishCard]) {
            self.cards = cards
            library = cards.indices.filter { !cards[$0].isCommander }
            commanders = cards.indices.filter { cards[$0].isCommander }
        }
    }

    /// A permanent that makes mana.
    private struct Source {
        let card: Int
        var tapped: Bool
        /// The turn its mana can first be used (a creature's: the next).
        let readyTurn: Int
    }

    private struct Game {
        let deck: Deck
        let config: GoldfishConfig
        var library: [Int] = []
        var hand: [Int] = []
        var sources: [Source] = []
        var landsOnField = 0
        var commandZone: [Int] = []
        var commanderCasts = 0
        var commanderCastTurn: Int?
        var mulligansTaken = 0
        var spellsCast = 0

        init(deck: Deck, config: GoldfishConfig) {
            self.deck = deck
            self.config = config
        }

        private func card(_ i: Int) -> GoldfishCard { deck.cards[i] }

        mutating func play<G: RandomNumberGenerator>(using rng: inout G, tally: inout Tally) {
            openingHand(using: &rng)
            tally.mulligans[min(mulligansTaken, tally.mulligans.count - 1)] += 1
            let kept = hand.filter { card($0).isLand }.count
            tally.keptLands[min(kept, 7)] += 1
            commandZone = deck.commanders

            var everyDrop = true
            var everStuck = false
            for turn in 1...config.turns {
                for i in sources.indices { sources[i].tapped = false }
                if !(turn == 1 && config.onThePlay) { draw(1) }

                let played = playLand(turn: turn)
                if played { tally.landDrop[turn] += 1 } else { everyDrop = false }
                if everyDrop { tally.everyLandDrop[turn] += 1 }

                let available = manaAvailable(turn: turn)
                tally.manaAvailable[turn] += Double(available)
                var spent = 0
                var stuck = false
                castLoop(turn: turn, spent: &spent, stuck: &stuck)
                tally.manaSpent[turn] += Double(spent)
                tally.spellsCast[turn] += Double(spellsCast)
                if stuck { tally.colorStuck[turn] += 1; everStuck = true }
                if everStuck { tally.colorStuckBy[turn] += 1 }
                tally.lands[turn] += Double(landsOnField)
                tally.handSize[turn] += Double(hand.count)
                if let castTurn = commanderCastTurn, castTurn <= turn { tally.commanderCastBy[turn] += 1 }
            }
            if let castTurn = commanderCastTurn { tally.commanderTurnSum += castTurn; tally.commanderGames += 1 }
            // Dead at the end: spells the whole untapped battlefield could not cast.
            for i in sources.indices { sources[i].tapped = false }
            let total = manaAvailable(turn: config.turns + 1)
            tally.deadCards += Double(hand.filter { i in
                let c = card(i)
                return c.isSpell && (c.manaValue > total || !canPay(c, turn: config.turns + 1, tax: 0))
            }.count)
        }

        // MARK: Opening hand

        private mutating func openingHand<G: RandomNumberGenerator>(using rng: inout G) {
            library = deck.library
            library.shuffle(using: &rng)
            hand = []
            draw(7)
            while mulligansTaken < config.maxMulligans {
                let lands = hand.filter { card($0).isLand }.count
                if lands >= config.minLands && lands <= config.maxLands { break }
                mulligansTaken += 1
                library.append(contentsOf: hand)
                hand = []
                library.shuffle(using: &rng)
                draw(7)
                bottom(mulligansTaken)
            }
        }

        /// London mulligan: the extra cards to the bottom — surplus lands
        /// first when there are too many, else the most expensive spells.
        private mutating func bottom(_ n: Int) {
            for _ in 0..<min(n, hand.count) {
                let lands = hand.filter { card($0).isLand }.count
                let choice: Int?
                if lands > config.maxLands {
                    choice = hand.first { card($0).isLand }
                } else {
                    choice = hand.filter { card($0).isSpell }.max { card($0).manaValue < card($1).manaValue }
                        ?? hand.first
                }
                guard let choice, let at = hand.firstIndex(of: choice) else { return }
                library.append(hand.remove(at: at))
            }
        }

        private mutating func draw(_ n: Int) {
            let count = min(n, library.count)
            guard count > 0 else { return }
            hand.append(contentsOf: library.prefix(count))
            library.removeFirst(count)
        }

        // MARK: Turns

        /// The land that helps most: untapped when there is something to
        /// cast with it, a colour the hand wants and the battlefield lacks.
        private mutating func playLand(turn: Int) -> Bool {
            let lands = hand.filter { card($0).isLand }
            guard !lands.isEmpty else { return false }
            let have = sources.reduce(UInt8(0)) { $0 | card($1.card).produces }
            let wanted = hand.filter { card($0).isSpell }.reduce(UInt8(0)) { acc, i in card(i).pips.reduce(acc) { $0 | $1 } }
            let missing = wanted & ~have
            let untappedMana = manaAvailable(turn: turn) + 1
            let wantUntapped = hand.contains { i in let c = card(i); return c.isSpell && c.manaValue <= untappedMana && c.manaValue > 0 }
                || commandZone.contains { card($0).manaValue + 2 * commanderCasts <= untappedMana }
            var best: (index: Int, score: Double)?
            for i in lands {
                let c = card(i)
                var score = 0.0
                if c.entersTapped != wantUntapped { score += 2 }
                score += Double((c.produces & missing).nonzeroBitCount) * 1.5
                score += Double(c.produces.nonzeroBitCount) * 0.1
                score += Double(c.manaAmount) * 0.3
                if best == nil || score > best!.score { best = (i, score) }
            }
            guard let best, let at = hand.firstIndex(of: best.index) else { return false }
            hand.remove(at: at)
            enterLand(best.index, tapped: card(best.index).entersTapped, turn: turn)
            return true
        }

        private mutating func enterLand(_ i: Int, tapped: Bool, turn: Int) {
            landsOnField += 1
            let c = card(i)
            if c.manaAmount > 0 { sources.append(Source(card: i, tapped: tapped, readyTurn: turn)) }
        }

        private func manaAvailable(turn: Int) -> Int {
            sources.reduce(0) { $0 + ((!$1.tapped && $1.readyTurn <= turn) ? card($1.card).manaAmount : 0) }
        }

        /// Casts while something fits: ramp, draw, the commander, then the
        /// biggest spell the mana allows.
        private mutating func castLoop(turn: Int, spent: inout Int, stuck: inout Bool) {
            var guardCount = 0
            while guardCount < 12 {
                guardCount += 1
                let available = manaAvailable(turn: turn)
                guard available > 0 else { break }
                let spells = hand.filter { card($0).isSpell }
                func order(_ i: Int) -> (Int, Int) {
                    let c = card(i)
                    if c.isRamp { return (0, c.manaValue) }
                    if c.draws > 0 { return (1, c.manaValue) }
                    return (3, -c.manaValue)
                }
                var candidates: [(index: Int, fromCommand: Bool, key: (Int, Int))] = spells.map { ($0, false, order($0)) }
                for i in commandZone { candidates.append((i, true, (2, 0))) }
                candidates.sort { $0.key < $1.key }
                var cast = false
                for candidate in candidates {
                    let c = card(candidate.index)
                    let tax = candidate.fromCommand ? 2 * commanderCasts : 0
                    guard c.manaValue + tax <= available else { continue }
                    if pay(c, turn: turn, tax: tax) {
                        spent += c.manaValue + tax
                        resolve(candidate.index, fromCommand: candidate.fromCommand, turn: turn)
                        cast = true
                        break
                    } else {
                        stuck = true
                    }
                }
                if !cast { break }
            }
        }

        private mutating func resolve(_ i: Int, fromCommand: Bool, turn: Int) {
            let c = card(i)
            if fromCommand {
                commandZone.removeAll { $0 == i }
                commanderCasts += 1
                if commanderCastTurn == nil { commanderCastTurn = turn }
            } else if let at = hand.firstIndex(of: i) {
                hand.remove(at: at)
            }
            spellsCast += 1
            if c.manaAmount > 0 {
                sources.append(Source(card: i, tapped: c.entersTapped, readyTurn: c.isCreatureProducer ? turn + 1 : turn))
            }
            for _ in 0..<c.fetchesLands { fetchLand(tapped: c.fetchedTapped, turn: turn) }
            if c.draws > 0 { draw(c.draws) }
        }

        /// A basic making a colour the hand wants and the battlefield
        /// lacks, else any basic, else any land.
        private mutating func fetchLand(tapped: Bool, turn: Int) {
            let have = sources.reduce(UInt8(0)) { $0 | card($1.card).produces }
            let wanted = hand.filter { card($0).isSpell }.reduce(UInt8(0)) { acc, i in card(i).pips.reduce(acc) { $0 | $1 } }
            let missing = wanted & ~have
            let pick = library.firstIndex { card($0).isBasic && card($0).produces & missing != 0 }
                ?? library.firstIndex { card($0).isBasic }
                ?? library.firstIndex { card($0).isLand }
            guard let pick else { return }
            let i = library.remove(at: pick)
            enterLand(i, tapped: tapped, turn: turn)
        }

        // MARK: Paying

        /// Whether the untapped sources can pay the cost: every coloured pip
        /// matched to a unit that makes it (a maximum bipartite matching —
        /// exact, and tiny), and enough units left for the generic part.
        private func canPay(_ c: GoldfishCard, turn: Int, tax: Int) -> Bool {
            assignment(c, turn: turn, tax: tax) != nil
        }

        private mutating func pay(_ c: GoldfishCard, turn: Int, tax: Int) -> Bool {
            guard let used = assignment(c, turn: turn, tax: tax) else { return false }
            for s in used { sources[s].tapped = true }
            return true
        }

        /// The sources to tap for the cost, or nil when it can't be paid.
        private func assignment(_ c: GoldfishCard, turn: Int, tax: Int) -> [Int]? {
            // Units: one per point of mana a ready source makes.
            var unitSource: [Int] = []
            var unitMask: [UInt8] = []
            for (s, source) in sources.enumerated() where !source.tapped && source.readyTurn <= turn {
                let card = card(source.card)
                for _ in 0..<card.manaAmount { unitSource.append(s); unitMask.append(card.produces) }
            }
            let generic = c.generic + tax
            guard unitMask.count >= c.pips.count + generic else { return nil }
            guard !c.pips.isEmpty || generic > 0 else { return [] }

            // Kuhn's augmenting paths: pip → unit.
            var matchOfUnit = [Int](repeating: -1, count: unitMask.count)
            func tryMatch(_ pip: Int, _ seen: inout [Bool]) -> Bool {
                for u in unitMask.indices where unitMask[u] & c.pips[pip] != 0 && !seen[u] {
                    seen[u] = true
                    if matchOfUnit[u] < 0 || tryMatch(matchOfUnit[u], &seen) {
                        matchOfUnit[u] = pip
                        return true
                    }
                }
                return false
            }
            for pip in c.pips.indices {
                var seen = [Bool](repeating: false, count: unitMask.count)
                if !tryMatch(pip, &seen) { return nil }
            }
            // Tap the matched units' sources; a source's other units are
            // free to cover generic.
            var tapped = Set<Int>()
            for u in matchOfUnit.indices where matchOfUnit[u] >= 0 { tapped.insert(unitSource[u]) }
            var covered = 0
            for u in unitMask.indices where tapped.contains(unitSource[u]) && matchOfUnit[u] < 0 { covered += 1 }
            var need = generic - covered
            if need > 0 {
                // The least flexible sources first, so colours stay open.
                let remaining = Set(unitSource).subtracting(tapped).sorted { a, b in
                    let ca = card(sources[a].card), cb = card(sources[b].card)
                    if ca.produces.nonzeroBitCount != cb.produces.nonzeroBitCount { return ca.produces.nonzeroBitCount < cb.produces.nonzeroBitCount }
                    return ca.manaAmount < cb.manaAmount
                }
                for s in remaining where need > 0 {
                    tapped.insert(s)
                    need -= card(sources[s].card).manaAmount
                }
                if need > 0 { return nil }
            }
            return Array(tapped)
        }
    }

    // MARK: Adding up

    private struct Tally {
        var landDrop: [Double]
        var everyLandDrop: [Double]
        var lands: [Double]
        var manaAvailable: [Double]
        var manaSpent: [Double]
        var spellsCast: [Double]
        var colorStuck: [Double]
        var colorStuckBy: [Double]
        var commanderCastBy: [Double]
        var handSize: [Double]
        var commanderTurnSum = 0
        var commanderGames = 0
        var mulligans: [Double]
        var keptLands = [Double](repeating: 0, count: 8)
        var deadCards = 0.0
        let hasCommander: Bool

        init(turns: Int, hasCommander: Bool) {
            self.hasCommander = hasCommander
            let zero = [Double](repeating: 0, count: turns + 1)
            landDrop = zero; everyLandDrop = zero; lands = zero; manaAvailable = zero; manaSpent = zero
            spellsCast = zero; colorStuck = zero; colorStuckBy = zero; commanderCastBy = zero; handSize = zero
            mulligans = [Double](repeating: 0, count: 4)
        }

        func result(games: Int, turns: Int, onThePlay: Bool) -> GoldfishResult {
            let n = Double(games)
            func mean(_ a: [Double]) -> [Double] { a.map { $0 / n } }
            return GoldfishResult(
                games: games, turns: turns, onThePlay: onThePlay,
                landDrop: mean(landDrop), everyLandDrop: mean(everyLandDrop), lands: mean(lands),
                manaAvailable: mean(manaAvailable), manaSpent: mean(manaSpent), spellsCast: mean(spellsCast),
                colorStuck: mean(colorStuck), colorStuckBy: mean(colorStuckBy),
                commanderCastBy: hasCommander ? mean(commanderCastBy) : [],
                commanderMeanTurn: commanderGames > 0 ? Double(commanderTurnSum) / Double(commanderGames) : nil,
                mulligans: mean(mulligans), keptLands: mean(keptLands),
                deadCardsAtEnd: deadCards / n, handSize: mean(handSize)
            )
        }
    }
}
