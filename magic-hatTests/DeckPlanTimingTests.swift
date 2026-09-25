import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// What the recommendations cost on the real collection: the catalog
/// slice, the real ManaBox export, the fixture deck; then the spare-card
/// fetch, every candidate read, and the plan — the work the add sheet's
/// Recommended scope waits on behind its loader. Off the main actor in
/// the app; here timed end to end and kept under a bound so a slower
/// regex or an extra pass over the collection shows up as a failure.
@Suite("DeckPlan timing", .serialized)
struct DeckPlanTimingTests {
    @Test @MainActor func planOverTheRealCollectionStaysQuick() async throws {
        let container = try TestSupport.makeContainer()
        try await BulkIngester.ingest(file: try TestSupport.fixtureURL("default_cards.slice.jsonl.gz"),
                                      dataset: .defaultCards, container: container)
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        _ = try await ImportController.apply(
            rows: rows, selectedBinders: Set(rows.map(\.binderName)),
            collectionName: "Library", mode: .add, container: container
        ) { _ in }
        let text = try String(contentsOf: try TestSupport.fixtureURL("KingUnderTheMountain.txt"), encoding: .utf8)
        let store = DeckStore(modelContainer: container)
        let resolved = try await store.resolve(DeckListParser.parse(text).lines)
        let ctx = container.mainContext
        let deck = try DeckEditController.createDeck(name: "King", format: .commander, commander: nil, context: ctx)
        try DeckEditController.importLines(resolved, into: deck.id, context: ctx)
        let snapshot = try #require(try await store.snapshot(deckID: deck.id))
        #expect(snapshot.playedItems.count > 40, "the slice resolves the part of the fixture deck the collection owns: \(snapshot.playedItems.count)")

        let clock = ContinuousClock()
        let t0 = clock.now
        let owned = try await store.collectionCandidates()
        let t1 = clock.now
        let readings = DeckAnalysis.readings(for: snapshot.playedItems, identity: snapshot.identity, tags: [:])
        let analysis = DeckAnalysis.compute(snapshot: snapshot, signals: .none, readings: readings)
        var candidateReadings: [String: CardReading] = [:]
        for c in owned { candidateReadings[c.card.id] = CardReading(c.card, identity: snapshot.identity) }
        let t2 = clock.now
        let candidates = owned.map { DeckCandidate(card: $0.card, ownedCopies: $0.ownedCopies, metaScore: nil) }
        let plan = DeckPlan.plan(snapshot: snapshot, analysis: analysis, signals: .none, candidates: candidates,
                                 readings: readings, candidateReadings: candidateReadings)
        let t3 = clock.now

        let ms = { (d: Duration) in d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000 }
        let line = "plan timing: \(owned.count) spare cards fetched in \(ms(t1 - t0))ms, read in \(ms(t2 - t1))ms, planned in \(ms(t3 - t2))ms → \(plan.recommendations.count) recommendations, \(plan.changeCount) changes"
        print(line)
        // Swift Testing's stdout does not reach xcodebuild's log; a file does.
        if let dir = ProcessInfo.processInfo.environment["UITEST_PERF_DIR"] ?? Optional("/tmp/perf") {
            try? (line + "\n").write(toFile: dir + "/plan-timing.txt", atomically: true, encoding: .utf8)
        }
        #expect(!plan.recommendations.isEmpty)
        #expect(analysis.isCommander)
        // Debug build on a simulator; a device release build is faster.
        #expect(t3 - t0 < .seconds(6), "the plan took \(ms(t3 - t0))ms")
        _ = container
    }
}
