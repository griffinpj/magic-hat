import Testing
import Foundation
@testable import magic_hat

/// Cards the user offers, judged by the planner that builds the swap table.
@Suite("Deck proposals")
struct DeckProposalTests {
    @Test func eachProposalGetsAVerdict() throws {
        var rows = try DeckAnalysisTests.precon()
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Vanilla", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])))
        rows.removeAll { $0.card.name == "Bear 28" }
        rows.removeAll { $0.card.name.hasPrefix("Tutor") }   // short two tutors
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Bear 28", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 200)))
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Bear 29", type: "Creature — Bear", text: "Lifelink", cost: "{2}{W}", colors: ["W"], rank: 200)))
        let snapshot = DeckPlanTests.snapshot(rows)
        let readings = DeckAnalysis.readings(for: snapshot.playedItems, identity: snapshot.identity, tags: [:])
        let analysis = DeckAnalysis.compute(snapshot: snapshot, signals: .none, readings: readings)

        let tutor = try DeckAnalysisTests.card("Enlightened Tutor", type: "Instant", text: "Search your library for an artifact or enchantment card, reveal it, then shuffle and put that card on top.", cost: "{W}", colors: ["W"])
        let bear = try DeckAnalysisTests.card("Another Bear", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"])
        let blue = try DeckAnalysisTests.card("Counterspell", type: "Instant", text: "Counter target spell.", cost: "{U}{U}", colors: ["U"])
        let dupe = rows[20].card
        let proposals = DeckPlan.propose([bear, tutor, blue, dupe].map { DeckPlanTests.candidate($0, owned: 0) },
                                         snapshot: snapshot, analysis: analysis, signals: .none, readings: readings)

        #expect(proposals.map(\.card.name) == ["Another Bear", "Enlightened Tutor", "Counterspell", dupe.name], "in the order given")
        guard case .swap(_, let out, _, let effect) = proposals[1].verdict else {
            Issue.record("the tutor fills a gap: \(proposals[1].verdict)"); return
        }
        #expect(out.name == "Vanilla" && effect != nil)
        #expect(proposals[1].reason != nil)
        guard case .notBetter(let weakest) = proposals[0].verdict else {
            Issue.record("a vanilla bear beats nothing: \(proposals[0].verdict)"); return
        }
        #expect(weakest?.name == "Vanilla", "the weakest card is named")
        #expect(proposals[2].verdict == .outsideIdentity)
        #expect(proposals[3].verdict == .alreadyInDeck)

        // One short of the size: the same card is simply an add.
        let short = DeckPlanTests.snapshot(Array(rows.dropLast()))
        let shortReadings = DeckAnalysis.readings(for: short.playedItems, identity: short.identity, tags: [:])
        let shortAnalysis = DeckAnalysis.compute(snapshot: short, signals: .none, readings: shortReadings)
        let added = DeckPlan.propose([DeckPlanTests.candidate(tutor, owned: 0)], snapshot: short, analysis: shortAnalysis,
                                     signals: .none, readings: shortReadings)
        guard case .add = added[0].verdict else { Issue.record("\(added[0].verdict)"); return }
    }

    private func judge(_ rows: [DeckCardItem], _ picks: [CardItem]) -> [DeckProposal] {
        let snapshot = DeckPlanTests.snapshot(rows)
        let readings = DeckAnalysis.readings(for: snapshot.playedItems, identity: snapshot.identity, tags: [:])
        let analysis = DeckAnalysis.compute(snapshot: snapshot, signals: .none, readings: readings)
        return DeckPlan.propose(picks.map { DeckPlanTests.candidate($0, owned: 0) }, snapshot: snapshot, analysis: analysis,
                                signals: .none, readings: readings)
    }

    /// A land is weighed against the lands: it takes a basic's place, not
    /// the weakest spell's, and a basic offered again is simply no better.
    @Test func aLandIsWeighedAgainstTheLands() throws {
        let rows = try DeckAnalysisTests.precon()      // 36 Plains, the floors met, 100 cards
        let temple = try DeckAnalysisTests.card("Temple of Light", type: "Land", text: "{T}: Add {W}.", rank: 300)
        let plains = try DeckAnalysisTests.card("Plains", type: "Basic Land — Plains")
        let proposals = judge(rows, [temple, plains])

        #expect(proposals[0].isLand)
        guard case .swap(let rowID, let out, let tag, let effect) = proposals[0].verdict else {
            Issue.record("a widely played land beats a basic: \(proposals[0].verdict)"); return
        }
        #expect(out.name == "Plains" && tag == .basicLand && effect != nil)
        #expect(rowID == rows[1].id.uuidString, "the row to take a copy from")
        #expect(proposals[0].options.first?.card.name == "Plains")
        guard case .notBetter(let weakest) = proposals[1].verdict else {
            Issue.record("another Plains for a Plains changes nothing: \(proposals[1].verdict)"); return
        }
        #expect(weakest?.name == "Plains" && proposals[1].isLand && proposals[1].options.isEmpty)
    }

    /// Short on lands, a land fills the gap like any card that fills one:
    /// it takes a spell's place. Long on lands, a spell takes a land's.
    @Test func landsShortOrOverChangeWhatIsCut() throws {
        var short = try DeckAnalysisTests.precon()
        short[1] = DeckAnalysisTests.row(short[1].card, qty: 30)
        for i in 0..<6 { short.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Cub \(i)", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"]))) }
        let temple = try DeckAnalysisTests.card("Temple of Light", type: "Land", text: "{T}: Add {W}.")
        let basic = try DeckAnalysisTests.card("Snow-Covered Plains", type: "Basic Snow Land — Plains")
        let filled = judge(short, [temple, basic])
        for proposal in filled {
            guard case .swap(_, let out, _, _) = proposal.verdict else {
                Issue.record("30 lands of 34: \(proposal.card.name) should come in for a spell, got \(proposal.verdict)"); continue
            }
            #expect(out.typeLine?.contains("Land") == false, "\(proposal.card.name) for \(out.name)")
            #expect(proposal.tags.contains(.gap(.lands, have: 30)) || proposal.tags.contains(.gap(.lands, have: 31)))
        }
        #expect(Set(filled.compactMap { p -> String? in if case .swap(let id, _, _, _) = p.verdict { return id }; return nil }).count == 2,
                "two picks, two different cuts")

        var over = try DeckAnalysisTests.precon()
        over[1] = DeckAnalysisTests.row(over[1].card, qty: 40)
        over.removeLast(4)
        let bear = try DeckAnalysisTests.card("Another Bear", type: "Creature — Bear", cost: "{1}{W}", colors: ["W"])
        let swapped = judge(over, [bear])
        guard case .swap(_, let out, let tag, _) = swapped[0].verdict else {
            Issue.record("40 lands: a spell may take a land's place, got \(swapped[0].verdict)"); return
        }
        #expect(out.name == "Plains" && tag == .landsOver(40))
        #expect(swapped[0].options.count > 1, "and the weakest spells are offered beside it")
    }

    /// The planner's cut leads the alternatives, which are the next-weakest
    /// rows, each re-scored.
    @Test func aSwapOffersOtherCuts() throws {
        var rows = try DeckAnalysisTests.precon()
        rows.removeAll { $0.card.name.hasPrefix("Tutor") }
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Vanilla", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])))
        rows.append(DeckAnalysisTests.row(try DeckAnalysisTests.card("Vanilla Two", type: "Creature — Bear", cost: "{3}{W}", colors: ["W"])))
        let tutor = try DeckAnalysisTests.card("Enlightened Tutor", type: "Instant", text: "Search your library for an artifact or enchantment card, reveal it, then shuffle and put that card on top.", cost: "{W}", colors: ["W"])
        let proposal = judge(rows, [tutor])[0]
        guard case .swap(let rowID, _, _, _) = proposal.verdict else { Issue.record("\(proposal.verdict)"); return }
        #expect(proposal.options.first?.rowID == rowID, "the verdict's cut leads")
        #expect(proposal.options.count == DeckPlan.cutOptions && Set(proposal.options.map(\.rowID)).count == DeckPlan.cutOptions)
        #expect(proposal.options.allSatisfy { $0.effect != nil })
        #expect(Set(proposal.options.prefix(2).map(\.card.name)) == ["Vanilla", "Vanilla Two"])
    }
}
