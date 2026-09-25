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
                     candidateReadings: [String: CardReading]) -> DeckPlan {
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
        var keepByRow: [String: (Double, String)] = [:]
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
            keepByRow[card.id] = (keep, text)
        }
        cuts.sort { $0.keep < $1.keep }
        let weights = Array(Set(keepByRow.values.map(\.0))).sorted()
        let place = Dictionary(uniqueKeysWithValues: weights.enumerated().map { ($1, $0 + 1) })
        let keep = keepByRow.mapValues { DeckKeep(score: $0.0, why: $0.1, rank: place[$0.0], ranked: keepByRow.count) }

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
            guard fits(c.card), !(c.card.typeLine ?? "").hasPrefix("Basic ") else { continue }
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
            if let price = c.card.priceUSD {
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
        let before = (analysis.power.score, analysis.impact.score, analysis.playability.score)
        var allReadings = readings
        for c in pool where allReadings[c.card.id] == nil { allReadings[c.card.id] = candidateReadings[c.card.id] }
        func effect(out: DeckCardItem?, `in`: DeckCandidate?) -> DeckSwapEffect? {
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
            if let c = `in` {
                after.append(DeckCardItem(id: UUID(), board: .main, quantity: 1, card: c.card, builtQuantity: 0, availableQuantity: c.ownedCopies))
            }
            var broke: [DeckCombo] = []
            var combos = analysis.combos
            if let out {
                let name = front(out.card.name)
                broke = combos.filter { $0.cards.contains { front($0) == name } }
                combos.removeAll { combo in broke.contains { $0.id == combo.id } }
            }
            var gained: [DeckCombo] = []
            if let c = `in` {
                let want = front(c.card.name)
                for combo in analysis.nearCombos where front(combo.missing ?? "") == want {
                    if let out, combo.cards.contains(where: { front($0) == front(out.card.name) }) { continue }
                    gained.append(combo); combos.append(combo)
                }
            }
            var signals2 = signals
            if signals.combos != nil { signals2.combos = DeckComboSet(included: combos, near: analysis.nearCombos) }
            let a = DeckAnalysis.compute(played: after, format: format, identity: identity, problems: analysis.problems,
                                         signals: signals2, readings: allReadings)
            let round = { (x: Double) in (x * 10).rounded() / 10 }
            return DeckSwapEffect(power: round(a.power.score - before.0), impact: round(a.impact.score - before.1),
                                  playability: round(a.playability.score - before.2),
                                  afterPower: a.power.score, afterImpact: a.impact.score, afterPlayability: a.playability.score,
                                  breaks: broke.prefix(4).map(\.title), gains: gained.prefix(4).map(\.title))
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
