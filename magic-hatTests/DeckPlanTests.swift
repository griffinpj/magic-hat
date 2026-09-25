import Testing
import Foundation
@testable import magic_hat

/// The swap table and the recommendations: rule problems out first, gaps
/// filled, no floor opened, and every line saying why.
@Suite("DeckPlan")
struct DeckPlanTests {
    static func snapshot(_ rows: [DeckCardItem], format: DeckFormat = .commander, identity: [ManaColor] = [.white]) -> DeckSnapshot {
        let commanders = rows.filter { $0.board == .commander }
        let main = rows.filter { $0.board == .main }
        let stats = DeckStats.compute(played: rows, format: format, identity: identity, allItems: rows)
        return DeckSnapshot(id: UUID(), name: "Plan Deck", format: format, isLocked: false, notes: "", createdDate: Date(), updatedDate: Date(),
                            identity: identity, commanders: commanders, sections: [DeckSection(id: "Other", title: "Other", glyph: nil, items: main)],
                            sideboard: [], maybeboard: [], stats: stats)
    }

    static func candidate(_ card: CardItem, owned: Int = 1, meta: Double? = nil) -> DeckCandidate {
        DeckCandidate(card: card, ownedCopies: owned, metaScore: meta)
    }

    static func run(_ snapshot: DeckSnapshot, signals: DeckAnalysisSignals = .none, candidates: [DeckCandidate]) -> (DeckAnalysis, DeckPlan) {
        let readings = DeckAnalysis.readings(for: snapshot.playedItems, identity: snapshot.identity, tags: signals.tags)
        let analysis = DeckAnalysis.compute(snapshot: snapshot, signals: signals, readings: readings)
        var cr: [String: CardReading] = [:]
        for c in candidates { cr[c.card.id] = CardReading(c.card, identity: snapshot.identity, tags: signals.tags) }
        return (analysis, DeckPlan.plan(snapshot: snapshot, analysis: analysis, signals: signals, candidates: candidates,
                                        readings: readings, candidateReadings: cr))
    }

    @Test func identityProblemsAndExtraCopiesComeOutFirst() throws {
        var rows = try DeckAnalysisTests.precon()
        let off = try DeckAnalysisTests.card("Counterspell", type: "Instant", text: "Counter target spell.", cost: "{U}{U}", colors: ["U"])
        rows[10] = DeckAnalysisTests.row(off)
        let twin = try DeckAnalysisTests.card("Twin", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"])
        rows[11] = DeckAnalysisTests.row(twin, qty: 2)
        let snapshot = Self.snapshot(rows)
        // Removal is past its floor, so the add's case is the engine: it gains life.
        let add = try DeckAnalysisTests.card("Path to Exile", type: "Instant", text: "Exile target creature. You gain 2 life.", cost: "{W}", colors: ["W"])
        let vanilla = try DeckAnalysisTests.card("Owned Bear", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"])
        let (_, plan) = Self.run(snapshot, candidates: [Self.candidate(add), Self.candidate(vanilla)])
        #expect(plan.trims.contains { $0.outCard.name == "Twin" && $0.quantity == 1 && $0.why.contains("singleton") }, "\(plan.trims.map(\.why))")
        let swap = plan.swaps.first
        #expect(swap?.outCard.name == "Counterspell" && swap?.outWhy == "outside the commander's colour identity", "\(plan.swaps.map(\.outWhy))")
        #expect(swap?.inCard.name == "Path to Exile")
        #expect(swap?.inWhy.contains("already yours") == true && swap?.inWhy.contains { $0.hasPrefix("touches lifegain") } == true, "\(swap?.inWhy ?? [])")
        #expect(!plan.recommendations.contains { $0.card.name == "Owned Bear" }, "owned alone is not a reason")
        // With nothing worth adding, the rule problem still comes out, as a cut.
        let (_, plan2) = Self.run(snapshot, candidates: [Self.candidate(vanilla)])
        #expect(plan2.swaps.isEmpty && plan2.trims.contains { $0.outCard.name == "Counterspell" }, "\(plan2.trims.map(\.outCard.name))")
        #expect(plan.keep[rows[12].card.id] != nil, "every spell has a keep score")
        #expect(plan.keep[rows[1].card.id] == nil, "lands are not ranked against spells")
    }

    @Test func aShortListFillsAndAnOverfullOneTrims() throws {
        let short = try Array(DeckAnalysisTests.precon().prefix(12))   // commander, lands, rocks: 47 cards, no draw
        var adds: [DeckCandidate] = []
        for i in 0..<20 { adds.append(Self.candidate(try DeckAnalysisTests.card("Cantrip \(i)", type: "Sorcery", text: "Draw two cards.", cost: "{1}{W}", colors: ["W"]))) }
        let (_, plan) = Self.run(Self.snapshot(short), candidates: adds)
        #expect(plan.fills.count == 15, "fills are capped at 15 per plan: \(plan.fills.count)")
        #expect(plan.fills.prefix(8).allSatisfy { $0.why.contains { $0.hasPrefix("fills card draw") } }, "\(plan.fills.map(\.why))")
        #expect(plan.fills[8].why.contains { $0.hasPrefix("touches card draw") }, "past the floor, still on-plan: \(plan.fills[8].why)")
        #expect(plan.fills.first?.effect != nil)
        #expect(plan.stillShort.contains(.removal))

        var over = try DeckAnalysisTests.precon()
        over.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Vanilla", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])))
        let (_, plan2) = Self.run(Self.snapshot(over), candidates: [])
        #expect(plan2.trims.count == 1 && plan2.trims.first?.why == "no role, no overlap with lifegain and card draw", "\(plan2.trims.map(\.why))")
        #expect(plan2.sizeAfter == 100)
    }

    @Test func swapsTakeTheWeakestOnlyWhenClearlyBetterAndNeverOpenAGap() throws {
        var rows = try DeckAnalysisTests.precon()
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Vanilla", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])))
        rows.removeAll { $0.card.name == "Bear 28" }
        rows.removeAll { $0.card.name.hasPrefix("Tutor") }   // now short two tutors
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Bear 28", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 200)))
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Bear 29", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 200)))
        let snapshot = Self.snapshot(rows)
        let tutor = try DeckAnalysisTests.card("Enlightened Tutor", type: "Instant", text: "Search your library for an artifact or enchantment card, reveal it, then shuffle and put that card on top.", cost: "{W}", colors: ["W"])
        let weakAdd = try DeckAnalysisTests.card("Another Bear", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"])
        let (analysis, plan) = Self.run(snapshot, candidates: [Self.candidate(tutor, owned: 0), Self.candidate(weakAdd)])
        #expect(analysis.shortRoles.map(\.role) == [.tutors])
        #expect(plan.swaps.count == 1, "only the tutor beats a keep score by two: \(plan.swaps.map { "\($0.inCard.name) for \($0.outCard.name)" })")
        #expect(plan.swaps.first?.outCard.name == "Vanilla", "the card with no role and no overlap goes first")
        #expect(plan.swaps.first?.inWhy.first?.hasPrefix("fills tutors") == true)
        #expect(plan.recommendations.first?.card.name == "Enlightened Tutor")
        #expect(plan.recommendations.map(\.card.name).contains("Another Bear") == false, "no gap, no overlap, nothing to say: not recommended")
        let effect = plan.swaps.first?.effect
        #expect(effect != nil && (effect!.power >= 0) && effect!.breaks.isEmpty)

        // The only removal at the floor is guarded even though it scores lowest.
        var thin = try DeckAnalysisTests.precon()
        thin.removeAll { $0.card.name.hasPrefix("Kill") && $0.card.name != "Kill 0" }
        for i in 1..<10 { thin.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Filler \(i)", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 100))) }
        thin.removeAll { $0.card.name == "Bear 0" }
        let kill = thin.first { $0.card.name == "Kill 0" }!
        let (_, plan2) = Self.run(Self.snapshot(thin), candidates: [Self.candidate(tutor)])
        #expect(!plan2.swaps.contains { $0.outRowID == kill.card.id }, "the one removal spell stays: \(plan2.swaps.map(\.outCard.name))")
    }

    @Test func comboPiecesAreKeptAndMissingPiecesLead() throws {
        var rows = try DeckAnalysisTests.precon()
        let piece = try DeckAnalysisTests.card("Piece", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])
        rows.append(DeckAnalysisTests.row(piece))
        rows.removeAll { $0.card.name == "Bear 0" }
        var signals = DeckAnalysisSignals.none
        signals.combos = DeckComboSet(
            included: [DeckCombo(id: "c", cards: ["Piece", "Bear 1"], produces: ["Infinite life"], bracketTag: "R", manaNeeded: "", popularity: 9, missing: nil)],
            near: [DeckCombo(id: "n", cards: ["Bear 2", "Missing Piece"], produces: ["Infinite mana"], bracketTag: "S", manaNeeded: "{2}", popularity: 7, missing: "Missing Piece")])
        let missing = try DeckAnalysisTests.card("Missing Piece", type: "Artifact", cost: "{2}")
        let tutor = try DeckAnalysisTests.card("Tutor X", type: "Instant", text: "Search your library for a card.", cost: "{W}", colors: ["W"])
        let (_, plan) = Self.run(Self.snapshot(rows), signals: signals, candidates: [Self.candidate(missing, owned: 0), Self.candidate(tutor)])
        let keep = plan.keep[piece.id]
        #expect(keep != nil && keep!.score >= 12 && keep!.why.hasPrefix("combos with Bear 1"), "\(String(describing: keep))")
        #expect(plan.recommendations.first?.card.name == "Missing Piece", "a combo completion leads whatever else it does")
        #expect(plan.recommendations.first?.completes == ["Bear 2 → infinite mana"])
        #expect(!plan.swaps.contains { $0.outCard.name == "Piece" }, "never cut what the deck wins with")
        // Cutting a piece would break the combo, and the effect says so.
        let (_, plan2) = Self.run(Self.snapshot(rows), signals: signals, candidates: [])
        let cutPiece = plan2.trims.first { $0.outCard.name == "Piece" }
        #expect(cutPiece == nil || cutPiece!.effect?.breaks.isEmpty == false)
    }

    @Test func keepScoreParts() {
        #expect(DeckPlan.keepScore(roles: [], overlap: 0, meta: nil, combos: 0, rank: nil) == 0)
        #expect(DeckPlan.keepScore(roles: [.ramp, .draw], overlap: 1, meta: 0.5, combos: 0, rank: 500) == 3 + 2 + 1.5 + 2)
        #expect(DeckPlan.keepScore(roles: [], overlap: 0, meta: nil, combos: 2, rank: nil) == 16)
    }
}
