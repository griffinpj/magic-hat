//
//  PriceHistoryTests.swift
//  magic-hatTests
//
//  The recorded prices: one sample a day with the day's later refresh
//  replacing the earlier, the packed blob round-tripping, the change
//  over a range, and the writer recording owned printings as prices land.
//

import Testing
import Foundation
import SwiftData
@testable import magic_hat

@Suite("Price history")
struct PriceHistoryTests {
    @Test func oneSamplePerDayAndRoundTrip() {
        var series = PriceSeries()
        let first = series.record(PriceSample(day: 10, usd: 1.0, usdFoil: nil, eur: 0.9, eurFoil: nil))
        #expect(first)
        let same = series.record(PriceSample(day: 10, usd: 1.0, usdFoil: nil, eur: 0.9, eurFoil: nil))
        #expect(!same, "the same day's same prices change nothing")
        let later = series.record(PriceSample(day: 10, usd: 1.2, usdFoil: nil, eur: 0.9, eurFoil: nil))
        #expect(later, "a later refresh the same day replaces")
        let earlier = series.record(PriceSample(day: 8, usd: 0.8, usdFoil: 3, eur: nil, eurFoil: nil))
        #expect(earlier)
        let empty = series.record(PriceSample(day: 11, usd: nil, usdFoil: nil, eur: nil, eurFoil: nil))
        #expect(!empty, "an empty sample is ignored")
        #expect(series.samples.map(\.day) == [8, 10], "oldest first")
        #expect(series.count == 2)

        let packed = series.packed
        #expect(packed.count == 2 * PriceSeries.recordSize)
        let back = PriceSeries(packed: packed)
        #expect(back == series)
        #expect(back.samples[0].usdFoil == 3 && back.samples[0].eur == nil, "nil survives as NaN")
    }

    @Test func pointsAndChange() {
        var series = PriceSeries()
        let today = PriceSample.day(of: Date())
        for (offset, price) in [(-40, 2.0), (-20, 2.5), (-1, 3.0), (0, 4.0)] {
            series.record(PriceSample(day: today + offset, usd: price, usdFoil: nil, eur: nil, eurFoil: nil))
        }
        #expect(series.points(foil: false, currency: .usd).map(\.price) == [2.0, 2.5, 3.0, 4.0])
        #expect(series.points(foil: false, currency: .eur).isEmpty, "no euro prices recorded")
        #expect(series.points(foil: true, currency: .usd).map(\.price) == [2.0, 2.5, 3.0, 4.0], "foil falls back to the nonfoil price")
        let month = series.change(over: 30, foil: false, currency: .usd)
        #expect(month?.amount == 2.0 && abs((month?.percent ?? 0) - 100) < 0.01, "against the sample on or before 30 days ago: 2.0 at −40 (2.5 at −20 is inside the month)")
        let week = series.change(over: 7, foil: false, currency: .usd)
        #expect(week?.amount == 1.5, "against the sample on or before a week ago: 2.5 at −20")
        let day = series.change(over: 1, foil: false, currency: .usd)
        #expect(day?.amount == 1.0, "against yesterday's 3.0")
        #expect(PriceSeries().change(over: 30, foil: false, currency: .usd) == nil)
    }

    @Test func dayArithmetic() {
        let d = PriceSample.day(of: PriceSample.epoch.addingTimeInterval(86_400 * 3 + 100))
        #expect(d == 3)
        #expect(PriceSample.date(of: 3) == PriceSample.epoch.addingTimeInterval(86_400 * 3))
    }

    /// The writer records a sample for every owned printing whose prices
    /// land — on a hydration (every card) and on a catalog ingest (only
    /// the owned ones) — one per day.
    @Test @MainActor func writerRecordsOwnedPrintings() async throws {
        let container = try TestSupport.makeContainer()
        let ctx = container.mainContext
        ctx.insert(MTGCollection(name: "Main"))
        ctx.insert(CollectionEntry(scryfallID: "owned", collectionName: "Main", quantity: 1))
        try ctx.save()
        let writer = CardMetaWriter.shared(for: container)

        func card(_ id: String, usd: String) -> ScryfallCard {
            let json = """
            {"object":"card","id":"\(id)","oracle_id":"o-\(id)","name":"\(id)","set":"one","set_name":"One","collector_number":"1",
             "rarity":"common","layout":"normal","prices":{"usd":"\(usd)"}}
            """
            return try! JSONDecoder().decode(ScryfallCard.self, from: Data(json.utf8))
        }
        // A catalog ingest: both printings' metadata, only the owned one recorded.
        try await writer.apply(cards: [card("owned", usd: "1.00"), card("other", usd: "5.00")], linkEntries: false)
        var rows = try ctx.fetch(FetchDescriptor<PriceHistory>())
        #expect(rows.map(\.scryfallID) == ["owned"])
        #expect(rows[0].series.last?.usd == 1.0)

        // A price refresh the same day: the day's sample replaced, not added.
        try await writer.apply(cards: [card("owned", usd: "1.50")], linkEntries: true)
        rows = try ctx.fetch(FetchDescriptor<PriceHistory>())
        #expect(rows.count == 1 && rows[0].series.count == 1 && rows[0].series.last?.usd == 1.5)
        #expect(rows[0].lastDay == PriceSample.day(of: Date()))

        let store = CollectionStore.shared(for: container)
        let series = try await store.priceHistory(scryfallID: "owned")
        #expect(series.count == 1)
        #expect(try await store.priceHistory(scryfallID: "other").isEmpty)
    }
}
