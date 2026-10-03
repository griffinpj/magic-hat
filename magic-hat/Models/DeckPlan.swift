//
//  DeckPlan.swift
//  magic-hat
//
//  The recommendations and the swap table, rules-based, no model involved.
//  Every card in the deck gets a keep score from the roles it fills, its
//  overlap with the commander's mechanics, its meta score and how widely
//  it is played; every candidate an add score from the gaps it fills, its
//  overlap, its meta score, whether it is already owned, and its price.
//  Cards outside the colour identity and extra copies come out first;
//  then the best add takes the weakest card while it is clearly better,
//  re-counting the floors after each pair so a cut never opens a gap.
//  Each line says which rule fired, and each carries the deck re-scored
//  with the swap applied — above all which combos it takes apart, which
//  a card's own score cannot see.
//
//  Pure and nonisolated, like DeckAnalysis: run off the main actor.
//

import Foundation

/// A card that could go in: from the collection (copies owned), from the
/// meta (Recommander's score), or the missing piece of a combo.
nonisolated struct DeckCandidate: Identifiable, Hashable, Sendable {
    let card: CardItem
    let ownedCopies: Int
    let metaScore: Double?
    var id: String { card.oracleID ?? card.scryfallID }
}

nonisolated struct DeckRecommendation: Identifiable, Hashable, Sendable {
    let candidate: DeckCandidate
    let score: Double
    /// The full case, as sentences (the tests read these).
    let reasons: [String]
    /// The same case in the standard vocabulary, strongest first; a row
    /// shows the first.
    let tags: [CardReason]
    let fills: [CardRole]
    /// Combos this card would complete ("A + B → infinite mana").
    let completes: [String]
    var id: String { candidate.id }
    var card: CardItem { candidate.card }
    var isOwned: Bool { candidate.ownedCopies > 0 }
    var reason: CardReason { tags.first ?? CardReason(.plan, "Fits the deck") }
}

/// The deck re-scored as if a swap had happened.
nonisolated struct DeckSwapEffect: Hashable, Sendable {
    let power: Double
    let impact: Double
    let playability: Double
    let afterPower: Double
    let afterImpact: Double
    let afterPlayability: Double
    let breaks: [String]
    let gains: [String]

    var isNeutral: Bool { power == 0 && impact == 0 && playability == 0 && breaks.isEmpty && gains.isEmpty }
}

nonisolated struct DeckSwap: Identifiable, Hashable, Sendable {
    let inCard: CardItem
    let inWhy: [String]
    let inTags: [CardReason]
    let outRowID: String
    let outCard: CardItem
    let outWhy: String
    let outTag: CardReason
    let effect: DeckSwapEffect?
    var id: String { inCard.id + "|" + outRowID }
    var inReason: CardReason { inTags.first ?? CardReason(.plan, "Fits the deck") }
}

nonisolated struct DeckFill: Identifiable, Hashable, Sendable {
    let inCard: CardItem
    let why: [String]
    let tags: [CardReason]
    let effect: DeckSwapEffect?
    var id: String { inCard.id }
    var reason: CardReason { tags.first ?? CardReason(.plan, "Fits the deck") }
}

nonisolated struct DeckTrim: Identifiable, Hashable, Sendable {
    let outRowID: String
    let outCard: CardItem
    let quantity: Int
    let why: String
    let tag: CardReason
    let effect: DeckSwapEffect?
    var id: String { outRowID + "|" + String(quantity) }
}

/// What a row of the deck is worth to it, and where that puts it among
/// the deck's spells (1 is the lightest — the first the table reaches for).
nonisolated struct DeckKeep: Hashable, Sendable {
    let score: Double
    let why: String
    let rank: Int?
    let ranked: Int
    /// The one tag that says why it would be the one to go.
    var tag: CardReason = .weakest
}

nonisolated struct DeckPlan: Hashable, Sendable {
    /// Fresh per plan: views key their rebuilds on it rather than comparing
    /// eighty recommendations card by card.
    let id = UUID()
    let engine: [String]
    let recommendations: [DeckRecommendation]
    let swaps: [DeckSwap]
    let fills: [DeckFill]
    let trims: [DeckTrim]
    let countsAfter: [CardRole: Int]
    let sourcesAfter: [ManaColor: Int]
    let stillShort: [CardRole]
    let sizeAfter: Int
    let targetSize: Int
    let keep: [String: DeckKeep]

    static let empty = DeckPlan(engine: [], recommendations: [], swaps: [], fills: [], trims: [], countsAfter: [:],
                                sourcesAfter: [:], stillShort: [], sizeAfter: 0, targetSize: 0, keep: [:])

    var changeCount: Int { swaps.count + fills.count + trims.count }

    // MARK: Planning

    /// `readings` covers the deck's rows (by CardItem id); `candidateReadings`
    /// the candidates (by their CardItem id). A missing reading is read on
    /// the spot.
    static func plan(snapshot: DeckSnapshot, analysis: DeckAnalysis, signals: DeckAnalysisSignals,
                     candidates: [DeckCandidate], readings: [String: CardReading],
                     candidateReadings: [String: CardReading], allowBasics: Bool = false) -> DeckPlan {
        let played = snapshot.playedItems
        let identity = snapshot.identity
        let identityKnown = analysis.isCommander
        let format = snapshot.format
        let engine = analysis.engine
        let front = CardReading.frontName
        let targetSize = analysis.targetSize ?? analysis.size
        func reading(_ item: DeckCardItem) -> CardReading {
            readings[item.card.id] ?? CardReading(item.card, identity: identity, tags: signals.tags)
        }
        func reading(_ c: DeckCandidate) -> CardReading {
            candidateReadings[c.card.id] ?? CardReading(c.card, identity: identity, tags: signals.tags)
        }
        func fits(_ card: CardItem) -> Bool {
            !identityKnown || Set(card.colorIdentity).isSubset(of: Set(identity))
        }

        // Which cards hold a combo together: a piece with no role and no
        // overlap would otherwise read as the weakest card in the list.
        var comboOf: [String: [DeckCombo]] = [:]
        for combo in analysis.combos { for name in combo.cards { comboOf[front(name), default: []].append(combo) } }

        var counts: [CardRole: Int] = Dictionary(uniqueKeysWithValues: analysis.composition.map { ($0.role, $0.count) })
        var sources: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: analysis.sources.map { ($0.color, $0.count) })
        let targets: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: analysis.sources.compactMap { s in s.target.map { (s.color, $0) } })
        let meta = signals.meta ?? [:]
        let metaOn = signals.meta != nil

        // --- Keep scores, weakest first ---------------------------------------
        struct Cut {
            let keep: Double
            let why: String
            let tag: CardReason
            let item: DeckCardItem
            let quantity: Int
            let roles: Set<CardRole>
        }
        var cuts: [Cut] = []
        var trims: [DeckTrim] = []
        var dupSeen: [String: Int] = [:]
        var keepByRow: [String: (Double, String, CardReason)] = [:]
        for item in played where item.board != .commander {
            let card = item.card
            let r = reading(item)
            var quantity = item.quantity
            if identityKnown, !fits(card) {
                cuts.append(Cut(keep: -100, why: "outside the commander's colour identity", tag: .outsideIdentity,
                                item: item, quantity: quantity, roles: r.roles))
                continue
            }
            if let limit = DeckStats.copyLimit(for: card, format: format) {
                let key = card.oracleID ?? card.scryfallID
                let seen = dupSeen[key] ?? 0
                dupSeen[key] = seen + quantity
                let extra = max(0, seen + quantity - limit) - max(0, seen - limit)
                if extra > 0 {
                    let allows = limit == 1 ? "singleton allows one" : "its own text allows up to \(limit)"
                    trims.append(DeckTrim(outRowID: card.id, outCard: card, quantity: extra,
                                          why: extra == 1 ? "the extra copy; \(allows)" : "\(extra) extra copies; \(allows)",
                                          tag: .extraCopies(extra), effect: nil))
                    if extra < quantity { quantity -= extra } else { continue }
                }
            }
            if r.isLand { continue }
            let overlap = r.overlap(with: engine)
            let m = card.oracleID.flatMap { meta[$0] }
            let inCombos = comboOf[front(card.name)] ?? []
            let keep = keepScore(roles: r.roles, overlap: overlap, meta: m, combos: inCombos.count, rank: card.edhrecRank)
            var why: [String] = []
            if let first = inCombos.first {
                let with = first.cards.filter { front($0) != front(card.name) }
                why.append(inCombos.count == 1 ? "combos with " + DeckAnalysis.list(Array(with.prefix(2))) : "part of \(inCombos.count) combos in this deck")
            }
            if r.roles.isEmpty { why.append("no role") }
            if !engine.isEmpty, overlap == 0 { why.append("no overlap with " + DeckAnalysis.list(engine)) }
            if DeckAnalysis.popularity(rank: card.edhrecRank) > 0, let rank = card.edhrecRank { why.append("widely played, EDHREC #\(rank)") }
            if let m { why.append("meta score \(Int((m * 100).rounded()))%") } else if metaOn { why.append("not in the meta's lists") }
            let text = why.isEmpty ? "the weakest of a solid list" : why.joined(separator: ", ")
            // One tag for the row: what most says why it is the one to go.
            let tag: CardReason = !inCombos.isEmpty ? .inCombos(inCombos.count)
                : (r.roles.isEmpty ? .noRole : (!engine.isEmpty && overlap == 0 ? .offPlan : .weakest))
            cuts.append(Cut(keep: keep, why: text, tag: tag, item: item, quantity: quantity, roles: r.roles))
            keepByRow[card.id] = (keep, text, tag)
        }
        cuts.sort { $0.keep < $1.keep }
        let weights = Array(Set(keepByRow.values.map(\.0))).sorted()
        let place = Dictionary(uniqueKeysWithValues: weights.enumerated().map { ($1, $0 + 1) })
        let keep = keepByRow.mapValues { DeckKeep(score: $0.0, why: $0.1, rank: place[$0.0], ranked: keepByRow.count, tag: $0.2) }

        // --- Candidates ---------------------------------------------------------
        let deckOracle = Set(played.compactMap { $0.card.oracleID })
        var usedName = Set(played.map { front($0.card.name) })
        var nearByName: [String: [DeckCombo]] = [:]
        for combo in analysis.nearCombos { if let missing = combo.missing { nearByName[front(missing), default: []].append(combo) } }
        func completes(_ card: CardItem) -> [String] {
            (nearByName[front(card.name)] ?? []).prefix(3).map { combo in
                combo.cards.filter { front($0) != front(card.name) }.joined(separator: " + ") + (combo.result.map { " → " + $0 } ?? "")
            }
        }
        var pool: [DeckCandidate] = []
        var seenPool = Set<String>()
        for c in candidates {
            guard !seenPool.contains(c.id), !usedName.contains(front(c.card.name)) else { continue }
            if let oracle = c.card.oracleID, deckOracle.contains(oracle) { continue }
            guard fits(c.card), allowBasics || !(c.card.typeLine ?? "").hasPrefix("Basic ") else { continue }
            seenPool.insert(c.id)
            pool.append(c)
        }

        struct Add {
            var score = 0.0
            var why: [String] = []
            var tags: [CardReason] = []
            var fills: [CardRole] = []
            /// The part that is only "already yours": a card with nothing
            /// else to say for it is not an add.
            var ownedBonus = 0.0
        }

        /// The add score against the counts as they stand now.
        func addScore(_ c: DeckCandidate) -> Add {
            let r = reading(c)
            var a = Add()
            for combo in nearByName[front(c.card.name)] ?? [] {
                a.score += 6
                let others = combo.cards.filter { front($0) != front(c.card.name) }
                a.why.append("completes " + others.joined(separator: " + ") + (combo.result.map { " → " + $0 } ?? ""))
                a.tags.append(.combo(with: others))
            }
            for role in CardRole.allCases where r.roles.contains(role) {
                let have = counts[role] ?? 0
                if have < role.floor {
                    a.score += 2 + Double(min(4, role.floor - have)) * 0.5
                    a.why.append("fills \(role.label.lowercased()), \(have) of \(role.floor)")
                    a.tags.append(.gap(role, have: have))
                    a.fills.append(role)
                }
            }
            if r.roles.contains(.lands) || r.roles.contains(.ramp) {
                for color in ManaColor.allCases where r.sources.contains(color) {
                    if let t = targets[color], (sources[color] ?? 0) < t {
                        a.score += 1.5
                        a.why.append("adds a \(color.name.lowercased()) source, \(sources[color] ?? 0) of ~\(t)")
                        a.tags.append(.source(color))
                        break
                    }
                }
            }
            let overlap = r.overlap(with: engine)
            if overlap > 0 {
                a.score += 1.5 * Double(overlap)
                let touched = r.touches(engine)
                a.why.append("touches " + DeckAnalysis.list(Array(touched.prefix(3))) + ", which the commander pays off")
                if let first = touched.first { a.tags.append(.plan(first)) }
            }
            if let m = c.metaScore { a.score += 6 * m; a.why.append("meta score \(Int((m * 100).rounded()))%"); a.tags.append(.meta(m)) }
            if c.ownedCopies > 0 { a.score += 1; a.ownedBonus = 1; a.why.append("already yours") }
            if let price = c.card.price {
                if price > 50 { a.score -= 2 } else if price > 20 { a.score -= 1 }
            }
            if r.isLegendaryCreature { a.score -= 0.25 }
            return a
        }

        // The recommendations: every candidate against the deck as it stands.
        var recs: [DeckRecommendation] = []
        for c in pool {
            let a = addScore(c)
            let done = completes(c.card)
            guard a.score - a.ownedBonus > 0 else { continue }
            recs.append(DeckRecommendation(candidate: c, score: a.score, reasons: a.why, tags: a.tags, fills: a.fills, completes: done))
        }
        recs.sort { a, b in
            if a.completes.isEmpty != b.completes.isEmpty { return !a.completes.isEmpty }
            if a.score != b.score { return a.score > b.score }
            return a.card.sortKey < b.card.sortKey
        }
        recs = Array(recs.prefix(80))

        // --- The table ----------------------------------------------------------
        var usedAdd = Set<String>()
        func apply(out: Cut?, outQuantity: Int, `in`: DeckCandidate?) {
            if let out {
                let r = reading(out.item)
                for role in r.roles { counts[role, default: 0] -= outQuantity }
                if r.roles.contains(.lands) || r.roles.contains(.ramp) { for color in r.sources { sources[color, default: 0] -= outQuantity } }
            }
            if let c = `in` {
                let r = reading(c)
                for role in r.roles { counts[role, default: 0] += 1 }
                if r.roles.contains(.lands) || r.roles.contains(.ramp) { for color in r.sources { sources[color, default: 0] += 1 } }
            }
        }
        func bestAdd() -> (DeckCandidate, Add)? {
            var best: (DeckCandidate, Add)?
            for c in pool where !usedAdd.contains(c.id) && !usedName.contains(front(c.card.name)) {
                let a = addScore(c)
                guard a.score - a.ownedBonus > 0 else { continue }
                if best == nil || a.score > best!.1.score { best = (c, a) }
            }
            return best
        }
        func take(_ c: DeckCandidate) { usedAdd.insert(c.id); usedName.insert(front(c.card.name)) }

        var swaps: [(in: DeckCandidate, add: Add, out: Cut)] = []
        var fills: [(in: DeckCandidate, add: Add)] = []
        var plainTrims: [(out: Cut, why: String)] = []
        var size = analysis.size
        // Extra copies first: they come out whatever else happens.
        for trim in trims {
            if let cut = cuts.first(where: { $0.item.card.id == trim.outRowID }) { apply(out: cut, outQuantity: trim.quantity, in: nil) }
            else if let item = played.first(where: { $0.card.id == trim.outRowID }) {
                let r = reading(item)
                for role in r.roles { counts[role, default: 0] -= trim.quantity }
                if r.roles.contains(.lands) || r.roles.contains(.ramp) { for color in r.sources { sources[color, default: 0] -= trim.quantity } }
            }
            size -= trim.quantity
        }
        let forced = cuts.filter { $0.keep < -50 }
        cuts.removeAll { $0.keep < -50 }
        for cut in forced {
            if let (c, a) = bestAdd(), a.score > 0 {
                take(c); apply(out: cut, outQuantity: cut.quantity, in: c)
                swaps.append((c, a, cut))
            } else {
                apply(out: cut, outQuantity: cut.quantity, in: nil)
                plainTrims.append((cut, cut.why))
                size -= cut.quantity
            }
        }
        while size < targetSize, fills.count < 15 {
            guard let (c, a) = bestAdd(), a.score > 0 else { break }
            take(c); apply(out: nil, outQuantity: 0, in: c)
            fills.append((c, a)); size += 1
        }
        while size > targetSize, !cuts.isEmpty {
            let cut = cuts.removeFirst()
            apply(out: cut, outQuantity: cut.quantity, in: nil)
            plainTrims.append((cut, cut.why)); size -= cut.quantity
        }
        while swaps.count < 10, !cuts.isEmpty {
            guard let (c, a) = bestAdd(), a.score > 0 else { break }
            let cut = cuts[0]
            // Never open a gap: a cut providing a role at or under its floor stays.
            let inRoles = reading(c).roles
            let guarded = cut.roles.contains { role in (counts[role] ?? 0) <= role.floor && !inRoles.contains(role) }
            if guarded { cuts.removeFirst(); continue }
            if a.score < cut.keep + 2 { break }
            cuts.removeFirst()
            take(c); apply(out: cut, outQuantity: cut.quantity, in: c)
            swaps.append((c, a, cut))
        }

        // --- What each change would do ------------------------------------------
        var allReadings = readings
        for c in pool where allReadings[c.card.id] == nil { allReadings[c.card.id] = candidateReadings[c.card.id] }
        func effect(out: DeckCardItem?, `in`: DeckCandidate?) -> DeckSwapEffect? {
            swapEffect(out: out, in: `in`, played: played, analysis: analysis, signals: signals, format: format,
                       identity: identity, readings: allReadings)
        }

        let stillShort = CardRole.allCases.filter { (counts[$0] ?? 0) < $0.floor }
        return DeckPlan(
            engine: engine,
            recommendations: recs,
            swaps: swaps.map { DeckSwap(inCard: $0.in.card, inWhy: $0.add.why, inTags: $0.add.tags, outRowID: $0.out.item.card.id,
                                        outCard: $0.out.item.card, outWhy: $0.out.why, outTag: $0.out.tag,
                                        effect: effect(out: $0.out.item, in: $0.in)) },
            fills: fills.map { DeckFill(inCard: $0.in.card, why: $0.add.why, tags: $0.add.tags, effect: effect(out: nil, in: $0.in)) },
            trims: trims.map { t in DeckTrim(outRowID: t.outRowID, outCard: t.outCard, quantity: t.quantity, why: t.why, tag: t.tag,
                                             effect: played.first { $0.card.id == t.outRowID }.flatMap { effect(out: $0, in: nil) }) }
                + plainTrims.map { DeckTrim(outRowID: $0.out.item.card.id, outCard: $0.out.item.card, quantity: $0.out.quantity,
                                            why: $0.why, tag: $0.out.tag, effect: effect(out: $0.out.item, in: nil)) },
            countsAfter: counts, sourcesAfter: sources, stillShort: stillShort,
            sizeAfter: size, targetSize: targetSize, keep: keep
        )
    }

    /// The deck re-scored as if one copy of `out` left and `in` joined:
    /// the three scores' movement, and the combos taken apart and gained,
    /// by arithmetic on what Spellbook already returned.
    static func swapEffect(out: DeckCardItem?, `in`: DeckCandidate?, played: [DeckCardItem], analysis: DeckAnalysis,
                           signals: DeckAnalysisSignals, format: DeckFormat, identity: [ManaColor],
                           readings: [String: CardReading]) -> DeckSwapEffect? {
        let front = CardReading.frontName
        let before = (analysis.power.score, analysis.impact.score, analysis.playability.score)
        var after: [DeckCardItem] = []
        for item in played {
            if let out, item.id == out.id {
                if item.quantity > 1 {
                    after.append(DeckCardItem(id: item.id, board: item.board, quantity: item.quantity - 1, card: item.card,
                                              builtQuantity: min(item.builtQuantity, item.quantity - 1), availableQuantity: item.availableQuantity))
                }
                continue
            }
            after.append(item)
        }
        var readings = readings
        if let c = `in` {
            after.append(DeckCardItem(id: UUID(), board: .main, quantity: 1, card: c.card, builtQuantity: 0, availableQuantity: c.ownedCopies))
            if readings[c.card.id] == nil { readings[c.card.id] = CardReading(c.card, identity: identity, tags: signals.tags) }
        }
        var broke: [DeckCombo] = []
        var combos = analysis.combos
        // A combo breaks only when the last copy of a piece leaves.
        if let out, out.quantity <= 1 {
            let name = front(out.card.name)
            broke = combos.filter { $0.cards.contains { front($0) == name } }
            combos.removeAll { combo in broke.contains { $0.id == combo.id } }
        }
        var gained: [DeckCombo] = []
        if let c = `in` {
            let want = front(c.card.name)
            for combo in analysis.nearCombos where front(combo.missing ?? "") == want {
                if let out, out.quantity <= 1, combo.cards.contains(where: { front($0) == front(out.card.name) }) { continue }
                gained.append(combo); combos.append(combo)
            }
        }
        var signals2 = signals
        if signals.combos != nil { signals2.combos = DeckComboSet(included: combos, near: analysis.nearCombos) }
        let a = DeckAnalysis.compute(played: after, format: format, identity: identity, problems: analysis.problems,
                                     signals: signals2, readings: readings)
        let round = { (x: Double) in (x * 10).rounded() / 10 }
        return DeckSwapEffect(power: round(a.power.score - before.0), impact: round(a.impact.score - before.1),
                              playability: round(a.playability.score - before.2),
                              afterPower: a.power.score, afterImpact: a.impact.score, afterPlayability: a.playability.score,
                              breaks: broke.prefix(4).map(\.title), gains: gained.prefix(4).map(\.title))
    }

    /// What a card is pulling its weight for: the roles it fills, its
    /// overlap with the commander's mechanics, its meta score, how widely
    /// it is played — and a bonus that puts a combo piece out of reach of
    /// any add.
    static func keepScore(roles: Set<CardRole>, overlap: Int, meta: Double?, combos: Int, rank: Int?) -> Double {
        var keep = Double(roles.count) * 1.5 + Double(overlap) * 2 + (meta.map { $0 * 3 } ?? 0) + DeckAnalysis.popularity(rank: rank)
        if combos > 0 { keep += 12 + 2 * Double(combos) }
        return (keep * 100).rounded() / 100
    }
}

// MARK: - Proposals

/// A card that could come out for a proposed one, with the deck re-scored
/// as if it did.
nonisolated struct DeckCutOption: Identifiable, Hashable, Sendable {
    /// The deck row's id (a UUID string).
    let rowID: String
    let card: CardItem
    let tag: CardReason
    let effect: DeckSwapEffect?
    var id: String { rowID }
}

/// What the planner makes of a card the user suggests: swap it in for a
/// card in the list, add it while the list is short, or keep the list as
/// it is — each with why.
nonisolated struct DeckProposal: Identifiable, Hashable, Sendable {
    enum Verdict: Hashable, Sendable {
        /// In, for `out` (a row of the list), with the deck re-scored.
        case swap(outRowID: String, out: CardItem, outTag: CardReason, effect: DeckSwapEffect?)
        /// In, with nothing out: the list is short of its size.
        case add(effect: DeckSwapEffect?)
        /// Not clearly better than the weakest card it would replace
        /// (a land for a land, a spell for a spell), which is named so
        /// the user can judge.
        case notBetter(weakest: CardItem?)
        case alreadyInDeck
        case outsideIdentity
    }

    let card: CardItem
    let verdict: Verdict
    /// Why the card would help, strongest first (empty when it wouldn't).
    let tags: [CardReason]
    /// The proposal is a land: it is weighed against the lands.
    var isLand = false
    /// What else could come out for it, weakest first — the verdict's own
    /// cut leads when it is a swap. The planner's pick is a default, not
    /// the only answer: the user may know the card they want gone.
    var options: [DeckCutOption] = []
    var id: String { card.id }
    var reason: CardReason? { tags.first }
}

nonisolated extension DeckPlan {
    /// How many more lands than the floor before a spell is offered a
    /// land's place.
    static let landSurplus = 4
    /// Alternatives offered beside the planner's own cut.
    static let cutOptions = 5

    /// Judges cards the user offers, in the order given.
    ///
    /// Spells run through the planner as its only candidates — the same
    /// scoring the swap table uses, so a proposal is judged the way a
    /// recommendation is: the strongest proposals claim the weakest rows
    /// first, a cut never opens a floor, and one card is never cut for two
    /// proposals.
    ///
    /// Lands are weighed against lands. The planner never cuts a land and
    /// scores an add by the gaps it fills, so a land offered to a deck
    /// with enough lands used to be told it was "not clearly better" than
    /// the weakest *spell*, and a basic was not judged at all. Here a land
    /// takes the place of the land worth least to the mana base (see
    /// `landValue`) when it is worth more, never leaving a colour short of
    /// its sources; while the deck is short of lands it goes through the
    /// planner like any card that fills a gap, and takes a spell's place.
    /// A spell that beats nothing is offered a land's place when the deck
    /// runs `landSurplus` lands over the floor.
    static func propose(_ cards: [DeckCandidate], snapshot: DeckSnapshot, analysis: DeckAnalysis,
                        signals: DeckAnalysisSignals, readings: [String: CardReading]) -> [DeckProposal] {
        let front = CardReading.frontName
        let played = snapshot.playedItems
        let inDeck = Set(played.map { front($0.card.name) })
        let identity = Set(snapshot.identity)
        let identityKnown = analysis.isCommander
        let format = snapshot.format
        var candidateReadings: [String: CardReading] = [:]
        for c in cards { candidateReadings[c.card.id] = CardReading(c.card, identity: snapshot.identity, tags: signals.tags) }
        func reading(_ c: DeckCandidate) -> CardReading { candidateReadings[c.card.id]! }
        func rowReading(_ item: DeckCardItem) -> CardReading {
            readings[item.card.id] ?? CardReading(item.card, identity: snapshot.identity, tags: signals.tags)
        }
        func effect(out: DeckCardItem?, in c: DeckCandidate) -> DeckSwapEffect? {
            swapEffect(out: out, in: c, played: played, analysis: analysis, signals: signals, format: format,
                       identity: snapshot.identity, readings: readings)
        }

        let landCount = analysis.composition.first { $0.role == .lands }?.count ?? 0
        let landFloor = CardRole.lands.floor
        let size = analysis.size
        let targetSize = analysis.targetSize ?? size
        // A format with no size to meet (casual) has room for anything:
        // what the planner doesn't swap in is simply an add.
        let noSizeRule = analysis.targetSize == nil
        let full = !noSizeRule && size >= targetSize
        // A land goes the planner's way only while lands are a gap.
        let landsAreShort = analysis.isCommander && landCount < landFloor
        let weighedAsLand = { (c: DeckCandidate) in reading(c).isLand && full && !landsAreShort }

        let plan = plan(snapshot: snapshot, analysis: analysis, signals: signals,
                        candidates: cards.filter { !weighedAsLand($0) },
                        readings: readings, candidateReadings: candidateReadings, allowBasics: true)
        let recs = Dictionary(plan.recommendations.map { ($0.card.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rowByCardID = Dictionary(played.map { ($0.card.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Spells' rows weakest first, for the alternatives.
        let weakRows = plan.keep.sorted { a, b in a.value.score != b.value.score ? a.value.score < b.value.score : a.key < b.key }
        let weakest = weakRows.first.flatMap { rowByCardID[$0.key]?.card }
        let claimed = Set(plan.swaps.map(\.outRowID))

        // The lands, by what each is worth to the mana base, least first.
        var sources: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: analysis.sources.map { ($0.color, $0.count) })
        let targets: [ManaColor: Int] = Dictionary(uniqueKeysWithValues: analysis.sources.compactMap { s in s.target.map { (s.color, $0) } })
        let comboNames = Set(analysis.combos.flatMap { $0.cards.map(front) })
        func landValue(_ card: CardItem, _ r: CardReading, meta: Double?) -> Double {
            var value = 0.0
            for color in r.sources where identity.isEmpty || identity.contains(color) {
                // A colour at or under its target needs every source it has.
                if let target = targets[color] { value += (sources[color] ?? 0) <= target ? 2 : 1 } else { value += 1 }
            }
            value += Double(r.roles.subtracting([.lands]).count) * 1.5
            value += Double(r.overlap(with: analysis.engine)) * 2
            value += (meta.map { $0 * 3 } ?? 0) + DeckAnalysis.popularity(rank: card.edhrecRank)
            if r.isBasic { value -= 0.5 }
            if comboNames.contains(front(card.name)) { value += 12 }
            return (value * 100).rounded() / 100
        }
        struct LandRow { let item: DeckCardItem; let reading: CardReading; var value: Double; var left: Int }
        var lands: [LandRow] = played.filter { $0.board != .commander }.compactMap { item in
            let r = rowReading(item)
            guard r.isLand else { return nil }
            return LandRow(item: item, reading: r, value: landValue(item.card, r, meta: item.card.oracleID.flatMap { signals.meta?[$0] }),
                           left: item.quantity)
        }
        func sortLands() {
            lands.sort { a, b in
                if a.value != b.value { return a.value < b.value }
                if a.reading.isBasic != b.reading.isBasic { return a.reading.isBasic }
                if a.item.quantity != b.item.quantity { return a.item.quantity > b.item.quantity }
                return a.item.card.sortKey < b.item.card.sortKey
            }
        }
        sortLands()
        /// Taking `land` out for `incoming` leaves no colour under its target
        /// that was at or over it.
        func keepsColours(_ land: LandRow, for incoming: CardReading?) -> Bool {
            for color in land.reading.sources {
                guard let target = targets[color], incoming?.sources.contains(color) != true else { continue }
                let have = sources[color] ?? 0
                if have >= target, have - 1 < target { return false }
            }
            return true
        }
        func landTag(_ land: LandRow) -> CardReason { land.reading.isBasic ? .basicLand : .weakestLand }
        func landOptions(for c: DeckCandidate, incoming: CardReading?) -> [DeckCutOption] {
            lands.filter { $0.left > 0 && keepsColours($0, for: incoming) }.prefix(cutOptions).map {
                DeckCutOption(rowID: $0.item.id.uuidString, card: $0.item.card, tag: landTag($0), effect: effect(out: $0.item, in: c))
            }
        }
        func spellOptions(for c: DeckCandidate, leading: String?) -> [DeckCutOption] {
            var rows = weakRows.filter { !claimed.contains($0.key) || $0.key == leading }
            if let leading, let i = rows.firstIndex(where: { $0.key == leading }) { rows.insert(rows.remove(at: i), at: 0) }
            return rows.prefix(cutOptions).compactMap { key, keep in
                guard let item = rowByCardID[key] else { return nil }
                return DeckCutOption(rowID: item.id.uuidString, card: item.card, tag: keep.tag, effect: effect(out: item, in: c))
            }
        }
        func take(_ land: LandRow, for incoming: CardReading) {
            guard let i = lands.firstIndex(where: { $0.item.id == land.item.id }) else { return }
            lands[i].left -= 1
            for color in land.reading.sources { sources[color, default: 0] -= 1 }
            for color in incoming.sources { sources[color, default: 0] += 1 }
        }

        return cards.map { c in
            let r = reading(c)
            let tags = recs[c.card.id]?.tags ?? []
            // More copies of a basic are always a fair question.
            if inDeck.contains(front(c.card.name)), !r.isBasic {
                return DeckProposal(card: c.card, verdict: .alreadyInDeck, tags: [], isLand: r.isLand)
            }
            if identityKnown, !Set(c.card.colorIdentity).isSubset(of: identity) {
                return DeckProposal(card: c.card, verdict: .outsideIdentity, tags: [], isLand: r.isLand)
            }

            if weighedAsLand(c) {
                let value = landValue(c.card, r, meta: c.metaScore)
                var why: [CardReason] = []
                if let short = r.sources.first(where: { color in targets[color].map { (sources[color] ?? 0) < $0 } ?? false }) {
                    why.append(.source(short))
                }
                if let touched = r.touches(analysis.engine).first { why.append(.plan(touched)) }
                if let m = c.metaScore { why.append(.meta(m)) }
                let options = landOptions(for: c, incoming: r)
                guard let cut = lands.first(where: { $0.left > 0 && keepsColours($0, for: r) }), let first = options.first else {
                    // No land it could take the place of without leaving a
                    // colour short: nothing to compare it with.
                    return DeckProposal(card: c.card, verdict: .notBetter(weakest: nil), tags: why, isLand: true)
                }
                // The same land again changes nothing.
                let same = front(cut.item.card.name) == front(c.card.name)
                if value >= cut.value + 0.5, !same {
                    take(cut, for: r)
                    return DeckProposal(card: c.card, verdict: .swap(outRowID: first.rowID, out: first.card, outTag: first.tag, effect: first.effect),
                                        tags: why, isLand: true, options: options)
                }
                return DeckProposal(card: c.card, verdict: .notBetter(weakest: cut.item.card), tags: why, isLand: true,
                                    options: options.filter { front($0.card.name) != front(c.card.name) })
            }

            if let swap = plan.swaps.first(where: { $0.inCard.id == c.card.id }) {
                let rowID = rowByCardID[swap.outRowID]?.id.uuidString ?? swap.outRowID
                return DeckProposal(card: c.card, verdict: .swap(outRowID: rowID, out: swap.outCard, outTag: swap.outTag, effect: swap.effect),
                                    tags: swap.inTags, isLand: r.isLand, options: spellOptions(for: c, leading: swap.outRowID))
            }
            if let fill = plan.fills.first(where: { $0.inCard.id == c.card.id }) {
                return DeckProposal(card: c.card, verdict: .add(effect: fill.effect), tags: fill.tags, isLand: r.isLand)
            }
            if noSizeRule {
                return DeckProposal(card: c.card, verdict: .add(effect: effect(out: nil, in: c)), tags: tags, isLand: r.isLand)
            }
            // A spell that beats no spell: with lands to spare, a land's place.
            if !r.isLand, analysis.isCommander, landCount - lands.reduce(0, { $0 + ($1.item.quantity - $1.left) }) >= landFloor + landSurplus,
               let cut = lands.first(where: { $0.left > 0 && keepsColours($0, for: nil) }) {
                let item = cut.item
                let option = DeckCutOption(rowID: item.id.uuidString, card: item.card, tag: .landsOver(landCount), effect: effect(out: item, in: c))
                take(cut, for: r)
                return DeckProposal(card: c.card, verdict: .swap(outRowID: option.rowID, out: option.card, outTag: option.tag, effect: option.effect),
                                    tags: tags, options: [option] + spellOptions(for: c, leading: nil))
            }
            return DeckProposal(card: c.card, verdict: .notBetter(weakest: weakest), tags: tags, isLand: r.isLand,
                                options: spellOptions(for: c, leading: nil))
        }
    }
}
