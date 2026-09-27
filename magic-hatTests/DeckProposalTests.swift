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
}
