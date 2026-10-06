//
//  OwnedIndexTests.swift
//  magic-hatTests
//
//  The ownership index every list of cards that isn't the collection is
//  marked from: a grouped result swaps to the printing owned, a list of
//  distinct printings keeps each, and every item learns how many deck
//  lists name its card.
//

import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("OwnedIndex")
struct OwnedIndexTests {
    private func owned(_ id: String, oracle: String, collection: String = "Main", finish: CardFinish = .normal,
                       quantity: Int = 1, image: String? = "img") -> CardItem {
        var item = TestSupport.card(id: id, name: "Card", quantity: quantity, finish: finish)
        item = CardItem(
            id: item.id, scryfallID: id, oracleID: oracle, name: item.name, setCode: item.setCode,
            setName: item.setName, collectorNumber: item.collectorNumber, rarity: item.rarity,
            quantity: quantity, finish: finish, condition: item.condition, language: item.language,
            addedDate: nil, owned: true, collectionName: collection, imageURL: image, artCropURL: nil,
            aspectRatio: item.aspectRatio, typeLine: nil, manaCost: nil, oracleText: nil, power: nil,
            toughness: nil, loyalty: nil, colors: [], colorIdentity: [], artist: nil, price: nil, priceFoil: nil,
            sortKey: item.sortKey, collectorNumberValue: item.collectorNumberValue,
            rarityRankValue: item.rarityRankValue, purchasePrice: nil, legalities: nil, edhrecRank: nil, purchaseURIs: nil
        )
        return item
    }

    private func hit(_ id: String, oracle: String) -> CardItem {
        var item = owned(id, oracle: oracle, collection: "")
        item.owned = false
        return item
    }

    /// A grouped hit for a card owned in another printing becomes that
    /// printing — a hit still (one copy, no row), owned; a hit for a card
    /// not owned is left alone, with its deck count.
    @Test func groupedHitSwapsToTheOwnedPrinting() {
        let index = CollectionStore.ownedIndex(
            of: [owned("p-foil", oracle: "o1", finish: .foil, quantity: 4), owned("p-plain", oracle: "o1", quantity: 1)],
            deckCounts: ["o1": 2, "o9": 1], stamp: nil
        )
        let marked = index.mark(hit("p-scryfall", oracle: "o1"), groupedPrintings: true)
        #expect(marked.scryfallID == "p-plain", "a non-foil row is preferred over a bigger foil stack")
        #expect(marked.id == "p-plain" && marked.owned && !marked.isEntry && marked.quantity == 1)
        #expect(marked.deckCount == 2)

        let other = index.mark(hit("x", oracle: "o9"), groupedPrintings: true)
        #expect(other.scryfallID == "x" && !other.owned && other.deckCount == 1)
    }

    /// Distinct printings (a set's cards) keep their printing and are
    /// owned only when that printing is.
    @Test func distinctPrintingsAreMarkedExactly() {
        let index = CollectionStore.ownedIndex(of: [owned("p1", oracle: "o1")], deckCounts: [:], stamp: nil)
        #expect(index.mark(hit("p1", oracle: "o1"), groupedPrintings: false).owned)
        let p2 = index.mark(hit("p2", oracle: "o1"), groupedPrintings: false)
        #expect(!p2.owned && p2.scryfallID == "p2")
    }

    /// A collection's row beats a deck's row as the printing to show, and
    /// a row with no image yet never stands in for a hit.
    @Test func printingPrefersCollectionRowsWithImages() {
        let index = CollectionStore.ownedIndex(
            of: [owned("in-deck", oracle: "o1", collection: "deck:1", quantity: 9),
                 owned("in-main", oracle: "o1"),
                 owned("pending", oracle: "o2", image: nil)],
            deckCounts: [:], stamp: nil
        )
        #expect(index.printingByKey["o1"]?.scryfallID == "in-main")
        #expect(index.printingByKey["o2"] == nil)
        #expect(index.copiesByKey["o1"] == 1, "deck rows are not available copies")
        #expect(index.ownedPrintingIDs.contains("in-deck"))
    }

    /// The store counts the deck lists naming a card, by oracle id, any
    /// board, each deck once — and the rows carry it.
    @Test @MainActor func rowsCarryDeckCounts() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        let meta = CardMeta(scryfallID: "a", name: "Alpha", fetchState: .fetched)
        meta.oracleID = "o-a"
        ctx.insert(meta)
        let entry = CollectionEntry(scryfallID: "a", collectionName: "Main", quantity: 2)
        entry.card = meta
        ctx.insert(entry)
        let deck1 = Deck(name: "One", format: .commander)
        let deck2 = Deck(name: "Two", format: .commander)
        ctx.insert(deck1); ctx.insert(deck2)
        for (deck, board) in [(deck1, DeckBoard.main), (deck1, .side), (deck2, .main)] {
            let card = DeckCard(scryfallID: "other-printing", oracleID: "o-a", name: "Alpha", board: board, quantity: 1)
            card.deck = deck
            ctx.insert(card)
        }
        try ctx.save()

        let store = CollectionStore.shared(for: container)
        let snapshot = try await store.snapshot(collectionName: "Main", sort: .name)
        #expect(snapshot.items.first?.deckCount == 2)
        let index = try await store.ownedIndex()
        #expect(index.deckCountByKey["o-a"] == 2)
    }
}
