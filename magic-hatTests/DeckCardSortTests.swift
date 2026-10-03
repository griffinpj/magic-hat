import Testing
import Foundation
@testable import magic_hat

/// The add sheet's orders: relevance leaves a list as it came, the rest
/// are total orders whose ties keep that order.
@Suite("DeckCardSort")
struct DeckCardSortTests {
    private func card(_ name: String, cost: String? = nil, price: Double? = nil, rarity: String = "common") -> CardItem {
        let meta = CardMeta(scryfallID: name, name: name, setCode: "tst", setName: "Test",
                            collectorNumber: "1", rarity: rarity, fetchState: .fetched)
        meta.manaCost = cost
        meta.priceUSD = price
        return CardItem(meta: meta, owned: false)
    }

    @Test func ordersByEachKeyAndKeepsTiesInPlace() {
        let rows = [
            card("Bolt", cost: "{R}", price: 1, rarity: "common"),
            card("Anger", cost: "{3}{R}", price: nil, rarity: "uncommon"),
            card("Crypt", cost: "{0}", price: 50, rarity: "rare"),
            card("Dash", cost: "{R}", price: 1, rarity: "mythic"),
        ]
        func names(_ sort: DeckCardSort, _ direction: SortDirection? = nil) -> [String] {
            sort.apply(rows, card: { $0 }, direction: direction).map(\.name)
        }
        #expect(names(.relevance) == ["Bolt", "Anger", "Crypt", "Dash"])
        #expect(names(.name) == ["Anger", "Bolt", "Crypt", "Dash"])
        #expect(names(.manaValue) == ["Crypt", "Bolt", "Dash", "Anger"])
        #expect(names(.price) == ["Crypt", "Bolt", "Dash", "Anger"], "unpriced last")
        #expect(names(.price, .ascending) == ["Bolt", "Dash", "Crypt", "Anger"], "unpriced last")
        #expect(names(.name, .descending) == ["Dash", "Crypt", "Bolt", "Anger"])
        #expect(names(.manaValue, .descending) == ["Anger", "Bolt", "Dash", "Crypt"])
        #expect(names(.rarity) == ["Dash", "Crypt", "Anger", "Bolt"])
        #expect(DeckCardSort.price.scryfall().sort == .price && DeckCardSort.price.scryfall().direction == .descending)
        #expect(DeckCardSort.price.scryfall(.ascending).direction == .ascending)
        #expect(DeckCardSort(stored: "Price (Low)") == .price)
        #expect(DeckCardSort.direction(sortRaw: "Price (Low)", directionRaw: "") == .ascending)
    }
}
