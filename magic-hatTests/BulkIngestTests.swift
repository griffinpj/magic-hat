import Testing
import Foundation
import SwiftData
import os
@testable import magic_hat

/// The catalog path, offline: real Scryfall JSONL slices (built by
/// scripts/make-fixtures.py from the same cards the ManaBox export
/// references) through the real gzip reader, decoder and upsert.
@Suite("Bulk ingest", .serialized)
struct BulkIngestTests {

    @Test @MainActor func cardSliceIngestsEveryLineWithFullMetadata() async throws {
        let file = try TestSupport.fixtureURL("default_cards.slice.jsonl.gz")
        let expected = try TestSupport.lineCount(file)
        #expect(expected > 3000)

        let container = try TestSupport.makeContainer()
        let lastProgress = OSAllocatedUnfairLock(initialState: 0)
        try await BulkIngester.ingest(file: file, dataset: .defaultCards, container: container) { done in
            lastProgress.withLock { $0 = done }
        }

        let metas = try container.mainContext.fetch(FetchDescriptor<CardMeta>())
        #expect(metas.count == expected)
        #expect(lastProgress.withLock { $0 } == expected)
        #expect(metas.allSatisfy { $0.fetchState == .fetched })
        #expect(metas.allSatisfy { !$0.name.isEmpty && $0.imageNormalURL != nil })
        #expect(metas.allSatisfy { $0.oracleID != nil && $0.pricesUpdatedAt != nil })
        // Prices are the whole point of the bulk file; most cards carry one.
        #expect(metas.filter { $0.priceUSD != nil }.count > metas.count / 2)
        // What the collection's colour and artist filters run on.
        #expect(metas.allSatisfy { $0.colorsRaw != nil && $0.colorIdentityRaw != nil })
        #expect(metas.filter { $0.artist != nil }.count > metas.count * 9 / 10)
    }

    @Test @MainActor func ingestIsIdempotent() async throws {
        let file = try TestSupport.fixtureURL("default_cards.slice.jsonl.gz")
        let container = try TestSupport.makeContainer()
        try await BulkIngester.ingest(file: file, dataset: .defaultCards, container: container)
        let first = try container.mainContext.fetch(FetchDescriptor<CardMeta>()).count
        try await BulkIngester.ingest(file: file, dataset: .defaultCards, container: container)
        #expect(try container.mainContext.fetch(FetchDescriptor<CardMeta>()).count == first)
    }

    @Test @MainActor func rulingsSliceIngestsAndIsIdempotent() async throws {
        let file = try TestSupport.fixtureURL("rulings.slice.jsonl.gz")
        // Scryfall's file contains a few byte-identical duplicate rulings; the
        // stable CardRuling id collapses them, so expect distinct, not lines.
        let lines = try TestSupport.lineCount(file)
        let expected = try TestSupport.distinctRulingCount(file)
        #expect(expected <= lines && expected > lines - 20)
        let container = try TestSupport.makeContainer()
        try await BulkIngester.ingest(file: file, dataset: .rulings, container: container)
        let rulings = try container.mainContext.fetch(FetchDescriptor<CardRuling>())
        #expect(rulings.count == expected)
        #expect(rulings.allSatisfy { !$0.oracleID.isEmpty && !$0.comment.isEmpty })
        // Stable ids: a second pass must not duplicate rows.
        try await BulkIngester.ingest(file: file, dataset: .rulings, container: container)
        #expect(try container.mainContext.fetch(FetchDescriptor<CardRuling>()).count == expected)
    }

    /// Catalog first, then import: the collection should come up already
    /// hydrated, with nothing pending except printings absent from
    /// default_cards (non-English etc.).
    @Test @MainActor func catalogThenImportLeavesNothingPending() async throws {
        let container = try TestSupport.makeContainer()
        try await BulkIngester.ingest(
            file: try TestSupport.fixtureURL("default_cards.slice.jsonl.gz"),
            dataset: .defaultCards, container: container
        )
        let rows = try CSVParser.parseManaBox(try TestSupport.manaBoxFixture())
        _ = try await ImportController.apply(
            rows: rows, selectedBinders: Set(rows.map(\.binderName)),
            collectionName: "Library", mode: .add, container: container
        ) { _ in }

        let known = Set(try container.mainContext.fetch(FetchDescriptor<CardMeta>())
            .filter { $0.fetchState == .fetched }.map(\.scryfallID))
        let snapshot = try await CollectionStore.shared(for: container)
            .snapshot(collectionName: "Library", sort: .priceHigh)

        #expect(snapshot.items.count == 3846)
        #expect(Set(snapshot.pendingIDs).isDisjoint(with: known))
        #expect(snapshot.stalePriceIDs.isEmpty)
        // Hydrated items carry images and a price sort that is mostly non-zero.
        let priced = snapshot.items.filter { $0.marketPrice != nil }
        #expect(priced.count > snapshot.items.count / 2)
        #expect(snapshot.items.first?.marketPrice ?? 0 >= snapshot.items.last?.marketPrice ?? 0)
        // Import linked entries to the catalog rows rather than creating blanks.
        let metaCount = try container.mainContext.fetch(FetchDescriptor<CardMeta>()).count
        #expect(metaCount == Set(rows.map(\.scryfallID)).count)
    }

    @Test func manifestFixtureHasBothDatasets() throws {
        let data = try Data(contentsOf: try TestSupport.fixtureURL("bulk-data.json"))
        let manifest = try JSONDecoder().decode(ScryfallBulkListResponse.self, from: data)
        for dataset in BulkDataset.allCases {
            let entry = try #require(manifest.data.first { $0.type == dataset.rawValue })
            #expect(entry.jsonlDownloadURI?.hasSuffix(".jsonl.gz") == true)
            #expect((entry.compressedSize ?? 0) > 1_000_000)
        }
    }
}
