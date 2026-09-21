import Testing
@testable import magic_hat

@Suite("CollectionEntry.mergeKey")
struct MergeKeyTests {
    @Test func samePrintingSameCollectionMerges() {
        let a = CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "normal", condition: "near_mint")
        let b = CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "normal", condition: "near_mint")
        #expect(a == b)
    }

    @Test func finishAndConditionSplitRows() {
        let base = CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "normal", condition: "near_mint")
        #expect(base != CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "foil", condition: "near_mint"))
        #expect(base != CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "normal", condition: "played"))
    }

    @Test func differentPrintingsNeverMerge() {
        let a = CollectionEntry.mergeKey(scryfallID: "one-10", collectionName: "Main", finish: "normal", condition: "near_mint")
        let b = CollectionEntry.mergeKey(scryfallID: "one-298", collectionName: "Main", finish: "normal", condition: "near_mint")
        #expect(a != b)
    }

    @Test func collectionsAreSeparateNamespaces() {
        let a = CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Main", finish: "normal", condition: "near_mint")
        let b = CollectionEntry.mergeKey(scryfallID: "s1", collectionName: "Trade", finish: "normal", condition: "near_mint")
        #expect(a != b)
    }
}
