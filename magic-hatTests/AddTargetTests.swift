import Testing
@testable import magic_hat

@Suite("AddTarget: the collection an Add starts on")
struct AddTargetTests {
    private let hit = TestSupport.card(id: "s1", name: "Sol Ring")   // an owned row in "Main"

    @Test func browsedCollectionWins() {
        #expect(AddTarget.resolve(browsing: "Trade", item: hit, last: "Main", existing: ["Main", "Trade"]) == "Trade")
    }

    @Test func ownedRowKeepsItsCollection() {
        #expect(AddTarget.resolve(browsing: nil, item: hit, last: "Trade", existing: ["Main", "Trade"]) == "Main")
    }

    @Test func lastUsedWhenNothingElseSays() {
        var searchHit = hit
        searchHit.owned = false
        #expect(AddTarget.resolve(browsing: nil, item: searchHit, last: "Trade", existing: ["Main", "Trade"]) == "Trade")
    }

    @Test func theOnlyCollection() {
        var searchHit = hit
        searchHit.owned = false
        #expect(AddTarget.resolve(browsing: nil, item: searchHit, last: nil, existing: ["Binder"]) == "Binder")
        #expect(AddTarget.resolve(browsing: nil, item: searchHit, last: nil, existing: ["A", "B"]) == "")
    }

    @Test func goneOrDeckNamesAreSkipped() {
        var searchHit = hit
        searchHit.owned = false
        #expect(AddTarget.resolve(browsing: "Deleted", item: searchHit, last: "Also gone", existing: ["A", "B"]) == "")
        #expect(AddTarget.resolve(browsing: "deck:1234", item: searchHit, last: nil, existing: ["deck:1234", "A"]) == "")
    }
}
