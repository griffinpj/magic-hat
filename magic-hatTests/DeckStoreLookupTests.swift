import Testing
import Foundation
import SwiftData
@testable import magic_hat

/// The catalog lookups the analysis and the synergy screen resolve names
/// and ids through: by Scryfall id, by oracle id (the owned printing
/// first), by name including a double-faced card's front face.
@MainActor
@Suite("DeckStore lookups")
struct DeckStoreLookupTests {
    @Test func lookupsByIDOracleAndName() async throws {
        let world = try DeckBuilderTests.makeWorld()
        let ctx = world.container.mainContext
        let dfc = CardMeta(scryfallID: "d1", name: "Bloomvine Regent // Claw-Tipped Hunter", setCode: "tst", setName: "Test",
                           collectorNumber: "d1", rarity: "rare", fetchState: .fetched)
        dfc.oracleID = "oracle-d"
        ctx.insert(dfc)
        try ctx.save()
        let store = DeckStore(modelContainer: world.container)

        let byID = try await store.items(scryfallIDs: ["b1", "a2", "nope"])
        #expect(byID.map(\.name) == ["Beta", "Alpha"], "in the order asked, unknown ids skipped")
        #expect(byID[0].owned == false && byID[1].owned == true)

        // By name where a name is known, by a scan where it is not.
        let byOracle = try await store.items(oracleIDs: ["oracle-a", "oracle-b", "oracle-zzz"], names: ["oracle-a": "Alpha"])
        #expect(Set(byOracle.keys) == ["oracle-a", "oracle-b"])
        #expect(byOracle["oracle-a"]?.owned == true && byOracle["oracle-b"]?.owned == false)

        let byName = try await store.items(names: ["Beta", "Bloomvine Regent", "Nobody"])
        #expect(byName["Beta"]?.scryfallID == "b1")
        #expect(byName["Bloomvine Regent"]?.scryfallID == "d1", "front face finds the double-faced card")
        #expect(byName["Nobody"] == nil)

        let owned = try await store.ownedCopiesByKey()
        #expect(owned["oracle-a"] == 3 && owned["oracle-c"] == 1 && owned["oracle-b"] == nil)
        let candidates = try await store.collectionCandidates()
        #expect(Set(candidates.map(\.card.name)) == ["Alpha", "Captain"] && candidates.first { $0.card.name == "Alpha" }?.ownedCopies == 3)
    }
}
