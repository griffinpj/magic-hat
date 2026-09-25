//
//  DeckAddSessionTests.swift
//  magic-hatTests
//
//  The add session's memory of what it wrote: the Recommended list hides
//  what the deck already plays but keeps what this sheet put in, so the
//  session — not the deck's counts, which the deck screen's re-plan can
//  race — has to say which is which.
//

import Testing
import SwiftData
@testable import magic_hat

@MainActor
@Suite("DeckAddSession")
struct DeckAddSessionTests {
    @Test func touchedRemembersWhatTheSessionWroteEvenAtZero() async throws {
        let w = try DeckBuilderTests.makeWorld()
        let ctx = w.container.mainContext
        let store = DeckStore.shared(for: w.container)
        let session = DeckAddSession(deckID: w.deck.id, context: ctx)
        session.update(from: try #require(try await store.snapshot(deckID: w.deck.id)))

        // Alpha is in the deck already; the session did not put it there.
        let alpha = CardItem(meta: try #require(try ctx.fetch(FetchDescriptor<CardMeta>()).first { $0.scryfallID == "a1" }), owned: true)
        #expect(session.quantity(of: alpha) == 2)
        #expect(session.touched.isEmpty)

        let delta = CardMeta(scryfallID: "d1", name: "Delta", setCode: "tst", setName: "Test", collectorNumber: "d1", rarity: "rare", fetchState: .fetched)
        delta.oracleID = "oracle-d"
        ctx.insert(delta)
        try ctx.save()
        let item = CardItem(meta: delta, owned: false)

        try session.add(item)
        #expect(session.quantity(of: item) == 1, "the count moves on the tap, before the deck is re-read")
        session.update(from: try #require(try await store.snapshot(deckID: w.deck.id)))
        #expect(session.quantity(of: item) == 1)
        try session.setQuantity(item, 3)
        #expect(session.quantity(of: item) == 3)
        session.update(from: try #require(try await store.snapshot(deckID: w.deck.id)))
        #expect(session.quantity(of: item) == 3)
        #expect(session.touched == ["oracle-d"])

        try session.setQuantity(item, 0)
        #expect(session.quantity(of: item) == 0)
        session.update(from: try #require(try await store.snapshot(deckID: w.deck.id)))
        #expect(session.quantity(of: item) == 0)
        #expect(session.touched == ["oracle-d"], "a card stepped back to zero stays where the list showed it")
    }
}
