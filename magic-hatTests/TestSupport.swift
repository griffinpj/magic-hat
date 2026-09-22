//
//  TestSupport.swift
//  magic-hatTests
//
//  Shared fixtures: an in-memory SwiftData container and terse builders for
//  the value types the tests exercise.
//

import Foundation
import SwiftData
@testable import magic_hat

/// Anchor so `Bundle(for:)` finds the test bundle (Swift Testing suites are
/// structs, and `Bundle.module` only exists for SwiftPM targets).
final class FixtureAnchor {}

enum TestSupport {
    /// The real ManaBox export checked in under Fixtures/. 3,872 rows, eight
    /// binders, CRLF line endings, and 17 printings that appear in more than
    /// one binder — the exact shape the import has to get right.
    static func manaBoxFixture() throws -> String {
        let bundle = Bundle(for: FixtureAnchor.self)
        let url = bundle.url(forResource: "ManaBox_Collection", withExtension: "csv")
            ?? bundle.url(forResource: "ManaBox_Collection", withExtension: "csv", subdirectory: "Fixtures")
        guard let url else { throw FixtureError.missing }
        return try String(contentsOf: url, encoding: .utf8)
    }

    enum FixtureError: Error { case missing }

    /// URL of a bundled fixture such as "default_cards.slice.jsonl.gz".
    static func fixtureURL(_ name: String) throws -> URL {
        let bundle = Bundle(for: FixtureAnchor.self)
        let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
        let base = parts[0], ext = parts.count > 1 ? parts[1] : nil
        let url = bundle.url(forResource: base, withExtension: ext)
            ?? bundle.url(forResource: base, withExtension: ext, subdirectory: "Fixtures")
        guard let url else { throw FixtureError.missing }
        return url
    }

    /// Distinct rulings in a rulings fixture, keyed the way CardRuling is.
    static func distinctRulingCount(_ url: URL) throws -> Int {
        let reader = try GzipLineReader(url: url)
        defer { reader.close() }
        let decoder = JSONDecoder()
        var ids = Set<String>()
        while let line = try reader.next() {
            guard let r = try? decoder.decode(ScryfallRulingLine.self, from: line),
                  let oracle = r.oracleId else { continue }
            ids.insert(CardRuling(oracleID: oracle, source: r.source ?? "scryfall",
                                  publishedAt: r.publishedAt ?? "", comment: r.comment ?? "").id)
        }
        return ids.count
    }

    /// Line count of a gzipped JSONL fixture, via the reader under test.
    static func lineCount(_ url: URL) throws -> Int {
        let reader = try GzipLineReader(url: url)
        defer { reader.close() }
        var n = 0
        while let line = try reader.next() { if !line.isEmpty { n += 1 } }
        return n
    }

    /// Keep the returned container alive for the whole test. `mainContext`
    /// does not retain it, and a context whose container has been freed
    /// traps inside SwiftData on its first fetch — which, because the unit
    /// tests share a process, takes every other running suite down with it.
    /// So: `let container = try makeContainer(); let ctx = container.mainContext`,
    /// never `makeContainer().mainContext`.
    @MainActor
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            MTGCollection.self, CollectionEntry.self, CardMeta.self,
            AuditRecord.self, CardRuling.self, SavedSearch.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    static func row(
        binder: String,
        id: String,
        name: String = "Forest",
        set: String = "BFZ",
        number: String = "272",
        finish: String = "normal",
        quantity: Int,
        condition: String = "near_mint",
        price: Double? = 0.15
    ) -> ManaBoxRow {
        ManaBoxRow(
            binderName: binder, binderType: "binder", name: name, setCode: set,
            setName: "Battle for Zendikar", collectorNumber: number, foil: finish,
            rarity: "common", quantity: quantity, manaBoxID: "1", scryfallID: id,
            purchasePrice: price, misprint: false, altered: false,
            condition: condition, language: "en", purchasePriceCurrency: "USD",
            added: nil
        )
    }

    static func card(
        id: String,
        name: String,
        set: String = "one",
        number: String = "1",
        rarity: String = "common",
        quantity: Int = 1,
        price: Double? = nil,
        paid: Double? = nil,
        added: Date? = nil,
        finish: CardFinish = .normal
    ) -> CardItem {
        CardItem(
            id: id, scryfallID: id, oracleID: nil, name: name, setCode: set,
            setName: set.uppercased(), collectorNumber: number, rarity: rarity,
            quantity: quantity, finish: finish, condition: "near_mint",
            language: "en", addedDate: added, owned: true, collectionName: "Main", imageURL: nil,
            artCropURL: nil, aspectRatio: 488.0 / 680.0, typeLine: nil,
            manaCost: nil, oracleText: nil, power: nil, toughness: nil,
            loyalty: nil, colors: [], colorIdentity: [], artist: nil,
            priceUSD: price, priceUSDFoil: nil,
            sortKey: CardItem.sortKey(for: name),
            collectorNumberValue: CardItem.collectorValue(number),
            rarityRankValue: CardItem.rarityRank(rarity),
            purchasePrice: paid,
            legalities: nil, edhrecRank: nil, purchaseURIs: nil
        )
    }
}
