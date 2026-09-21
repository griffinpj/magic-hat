import Testing
import Foundation
@testable import magic_hat

@Suite("CardSorting")
struct CardSortingTests {
    /// Swift's sort is not stable. With thousands of cards sharing a key
    /// (no price yet), a comparator without a total order returns a
    /// different permutation on every call — which is what the grid was doing.
    @Test func priceSortIsDeterministicUnderShuffle() {
        var items: [CardItem] = (0..<300).map {
            TestSupport.card(id: "c\($0)", name: "Card \($0 % 50)", price: $0 % 25 == 0 ? Double($0) : nil)
        }
        let reference = CardSorting.sorted(items, by: .priceHigh)
        for _ in 0..<5 {
            items.shuffle()
            #expect(CardSorting.sorted(items, by: .priceHigh).map(\.id) == reference.map(\.id))
        }
    }

    @Test func pricedCardsComeFirstDescendingThenUnpricedAlphabetical() {
        let items = [
            TestSupport.card(id: "a", name: "Zebra", price: nil),
            TestSupport.card(id: "b", name: "Apple", price: nil),
            TestSupport.card(id: "c", name: "Mid", price: 5),
            TestSupport.card(id: "d", name: "Top", price: 50),
        ]
        let sorted = CardSorting.sorted(items, by: .priceHigh).map(\.name)
        #expect(sorted == ["Top", "Mid", "Apple", "Zebra"])
    }

    @Test func nameTiesBreakOnIdSoOrderIsTotal() {
        let items = [TestSupport.card(id: "b", name: "Same"), TestSupport.card(id: "a", name: "Same")]
        #expect(CardSorting.sorted(items, by: .name).map(\.id) == ["a", "b"])
    }

    @Test func setSortUsesNumericCollectorNumbers() {
        let items = [
            TestSupport.card(id: "x", name: "X", set: "one", number: "10"),
            TestSupport.card(id: "y", name: "Y", set: "one", number: "9"),
            TestSupport.card(id: "z", name: "Z", set: "abc", number: "100"),
        ]
        #expect(CardSorting.sorted(items, by: .setCode).map(\.id) == ["z", "y", "x"])
    }

    @Test func sortKeysFoldCaseAndDiacriticsAndParseNumbers() {
        #expect(CardItem.sortKey(for: "Élan") == CardItem.sortKey(for: "elan"))
        #expect(CardItem.sortKey(for: "Zebra") > CardItem.sortKey(for: "apple"))
        #expect(CardItem.collectorValue("216") == 216)
        #expect(CardItem.collectorValue("216s") == 216, "variant suffix still orders by its number")
        #expect(CardItem.collectorValue("★") == Int.max)
        #expect(CardItem.rarityRank("Mythic") == 3)
        #expect(CardItem.rarityRank("weird") == -1)
    }

    /// The whole reason for precomputed keys: sorting a real-sized grid must
    /// be cheap enough to run on the main actor without a visible pause.
    @Test func sortingFourThousandCardsIsFast() {
        let items: [CardItem] = (0..<4000).map {
            TestSupport.card(id: "c\($0)", name: "Card \($0 % 700)", set: ["one", "mom", "ltr"][$0 % 3],
                             number: "\($0 % 300)", rarity: ["common", "rare", "mythic"][$0 % 3],
                             price: $0 % 5 == 0 ? Double($0 % 90) : nil)
        }
        let start = ContinuousClock.now
        for sort in CardSort.allCases { _ = CardSorting.sorted(items, by: sort) }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(250), "all six sorts took \(elapsed)")
    }

    @Test func raritySortsMythicFirst() {
        let items = [
            TestSupport.card(id: "1", name: "C", rarity: "common"),
            TestSupport.card(id: "2", name: "M", rarity: "mythic"),
            TestSupport.card(id: "3", name: "R", rarity: "rare"),
        ]
        #expect(CardSorting.sorted(items, by: .rarity).map(\.rarity) == ["mythic", "rare", "common"])
    }
}

@Suite("PriceFormat")
struct PriceFormatTests {
    @Test func compactDropsCentsAtOrAboveOneHundred() {
        #expect(PriceFormat.compact(140) == "$140")
        #expect(PriceFormat.compact(38.22) == "$38.22")
    }

    @Test func changeIsSignedWithPercent() {
        #expect(PriceFormat.change(2.03, 5.61) == "+2.03 (+5.6%)")
        #expect(PriceFormat.change(-6.81, -4.64) == "-6.81 (-4.6%)")
    }

    @Test func gainLossDerivesFromPurchasePrice() {
        let up = TestSupport.card(id: "1", name: "A", price: 12, paid: 10)
        #expect(up.gainLoss?.amount == 2)
        #expect(up.gainLoss.map { abs($0.percent - 20) < 0.001 } == true)
        #expect(TestSupport.card(id: "2", name: "B", price: 12, paid: nil).gainLoss == nil)
    }
}
