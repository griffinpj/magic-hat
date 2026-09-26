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
        func names(_ sort: DeckCardSort) -> [String] { sort.apply(rows, card: { $0 }).map(\.name) }
        #expect(names(.relevance) == ["Bolt", "Anger", "Crypt", "Dash"])
        #expect(names(.name) == ["Anger", "Bolt", "Crypt", "Dash"])
        #expect(names(.manaValue) == ["Crypt", "Bolt", "Dash", "Anger"])
        #expect(names(.priceHigh) == ["Crypt", "Bolt", "Dash", "Anger"], "unpriced last")
        #expect(names(.priceLow) == ["Bolt", "Dash", "Crypt", "Anger"], "unpriced last")
        #expect(names(.rarity) == ["Dash", "Crypt", "Anger", "Bolt"])
        #expect(DeckCardSort.priceHigh.scryfall.sort == .price && DeckCardSort.priceHigh.scryfall.direction == .descending)
    }
}
