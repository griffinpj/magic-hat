//
//  UITestSeed.swift
//  magic-hat
//
//  Deterministic fixture data for UI and performance tests, used when the app
//  is launched with `-uitest-seed`. In-memory store, no network: image URLs
//  are nil so tiles render their placeholder, and the catalog is marked ready
//  so the setup screen is skipped.
//

import Foundation
import SwiftData

@MainActor
enum UITestSeed {
    static let collectionName = "Test Collection"
    /// `-uitest-seed`: an in-memory store and no network. The analysis and
    /// the synergy screen check this before asking anything outside.
    nonisolated static var isSeededRun: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-seed")
    }
    /// 900 by default (the scroll baseline was set on it); a test can ask
    /// for more with `UITEST_SEED_COUNT`.
    static var cardCount: Int {
        Int(ProcessInfo.processInfo.environment["UITEST_SEED_COUNT"] ?? "") ?? 900
    }

    static func populate(_ container: ModelContainer) {
        // Preferences persist on the simulator between runs; a sort left
        // behind by one test must not reorder the grid for the next.
        UserDefaults.standard.removeObject(forKey: "collection.sort")
        let context = container.mainContext
        context.insert(MTGCollection(name: collectionName))

        for i in 0..<cardCount {
            let id = String(format: "00000000-0000-4000-8000-%012d", i)
            let meta = CardMeta(
                scryfallID: id,
                name: "Card \(i)",
                setCode: ["one", "mom", "ltr", "woe"][i % 4],
                setName: "Set \(i % 4)",
                collectorNumber: "\(i)",
                rarity: ["common", "uncommon", "rare", "mythic"][i % 4],
                fetchState: .fetched
            )
            meta.priceUSD = Double(i % 50)
            meta.pricesUpdatedAt = Date()
            // Something for every collection filter to bite on.
            meta.colorsRaw = ["W", "U", "B", "R", "G", ""][i % 6]
            meta.colorIdentityRaw = meta.colorsRaw
            meta.typeLine = i % 3 == 0 ? "Creature — Dragon" : "Instant"
            meta.oracleText = i % 2 == 0 ? "Flying" : "Draw a card."
            meta.manaCost = "{\(i % 5)}{\(["W", "U", "B", "R", "G", "C"][i % 6])}"
            meta.artist = "Artist \(i % 7)"
            context.insert(meta)

            let entry = CollectionEntry(
                scryfallID: id,
                collectionName: collectionName,
                name: meta.name,
                setCode: meta.setCode,
                setName: meta.setName,
                collectorNumber: meta.collectorNumber,
                rarity: meta.rarity,
                finish: i % 7 == 0 ? .foil : .normal,
                quantity: 1 + i % 4,
                purchasePrice: Double(i % 40)
            )
            entry.card = meta
            context.insert(entry)
        }
        try? context.save()
        CatalogSyncController.shared.markCatalogReadyForTesting()
    }

    static let realCollectionName = "Real Collection"

    /// `-uitest-real`: the setup screen is skipped (the catalog download is
    /// the one thing not exercised); everything else — hydration, prices,
    /// images — is the real thing over the network.
    static func prepareRealRun() {
        UserDefaults.standard.removeObject(forKey: "collection.sort")
        CatalogSyncController.shared.markCatalogReadyForTesting()
    }

    /// `UITEST_IMPORT_CSV=<path to a ManaBox export>`: imported once, into
    /// "Real Collection", the way the wizard does it (parsed off-main,
    /// written on the background writer). A store that already has rows
    /// keeps them — the second launch is the one with an existing
    /// collection, which is what a real user opens every day.
    static func importRealCollectionIfNeeded(_ container: ModelContainer) async {
        guard let path = ProcessInfo.processInfo.environment["UITEST_IMPORT_CSV"], !path.isEmpty else { return }
        let store = CollectionStore.shared(for: container)
        if let names = try? await store.entryCollectionNames(), !names.isEmpty { return }
        // `UITEST_INGEST_FILE` with a real run: the bulk slice stands in for
        // the catalog (the 79MB download is the one thing skipped), so
        // names and ids resolve locally the way they do on a device.
        if let ingest = ProcessInfo.processInfo.environment["UITEST_INGEST_FILE"], !ingest.isEmpty {
            try? await BulkIngester.ingest(file: URL(fileURLWithPath: ingest), dataset: .defaultCards, container: container)
        }
        let rows: [ManaBoxRow] = await Task.detached(priority: .userInitiated) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            return (try? CSVParser.parseManaBox(text)) ?? []
        }.value
        guard !rows.isEmpty else { return }
        _ = try? await ImportController.apply(
            rows: rows, selectedBinders: Set(rows.map(\.binderName)), collectionName: realCollectionName,
            mode: .add, container: container, progress: { _ in }
        )
    }

    /// `UITEST_INGEST_FILE=<path to a .jsonl.gz>`: keeps the catalog writer
    /// busy for the life of the test by ingesting that file over and over
    /// (`UITEST_INGEST_PASSES`, default 20), the way a first-launch catalog
    /// sync does, so a UI test can measure the app *while* rows are
    /// landing. No network; the file is a bulk slice from the fixtures.
    static func startIngestLoopIfRequested(_ container: ModelContainer) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["UITEST_INGEST_FILE"] else { return }
        let passes = Int(env["UITEST_INGEST_PASSES"] ?? "") ?? 20
        let file = URL(fileURLWithPath: path)
        Task.detached(priority: .background) {
            for _ in 0..<passes {
                try? await BulkIngester.ingest(file: file, dataset: .defaultCards, container: container)
            }
        }
    }
}
