//
//  BulkIngester.swift
//  magic-hat
//
//  Turns a downloaded Scryfall bulk file (`.jsonl.gz`) into rows in the
//  store. Split out of CatalogSyncController so it can be run against a
//  fixture slice in tests, with no network and no UserDefaults.
//
//  Parsing runs on a detached task; each decoded batch is awaited onto the
//  main actor to be written. SwiftData models are written on the main
//  context in this app, and awaiting each batch also throttles the reader,
//  so memory stays flat regardless of file size.
//

import Foundation
import SwiftData

nonisolated enum BulkIngester {
    static let batchSize = 500

    /// Ingests `file` for `dataset`, calling `progress` with the running
    /// line count (sparsely — about once per ten batches).
    static func ingest(
        file: URL,
        dataset: BulkDataset,
        container: ModelContainer,
        progress: @escaping @Sendable (Int) -> Void = { _ in }
    ) async throws {
        let size = batchSize
        try await Task.detached(priority: .utility) {
            let reader = try GzipLineReader(url: file)
            defer { reader.close() }
            let decoder = JSONDecoder()
            var done = 0

            while true {
                try Task.checkCancellation()
                let lines = try reader.nextBatch(size)
                if lines.isEmpty { break }

                switch dataset {
                case .defaultCards:
                    let cards = lines.compactMap { try? decoder.decode(ScryfallCard.self, from: $0) }
                    if !cards.isEmpty {
                        await MainActor.run { upsert(cards: cards, container: container) }
                    }
                case .rulings:
                    let rulings = lines
                        .compactMap { try? decoder.decode(ScryfallRulingLine.self, from: $0) }
                        .filter { $0.oracleId != nil }
                    if !rulings.isEmpty {
                        await MainActor.run { insert(rulings: rulings, container: container) }
                    }
                }

                done += lines.count
                if done % (size * 10) == 0 || lines.count < size {
                    progress(done)
                }
            }
        }.value
    }

    @MainActor
    private static func upsert(cards: [ScryfallCard], container: ModelContainer) {
        let context = container.mainContext
        let ids = cards.map(\.id)
        let existing = (try? context.fetch(
            FetchDescriptor<CardMeta>(predicate: #Predicate { ids.contains($0.scryfallID) })
        )) ?? []
        var byID = Dictionary(existing.map { ($0.scryfallID, $0) }, uniquingKeysWith: { a, _ in a })

        for card in cards {
            let meta: CardMeta
            if let found = byID[card.id] {
                meta = found
            } else {
                let created = CardMeta(scryfallID: card.id)
                context.insert(created)
                byID[card.id] = created
                meta = created
            }
            meta.apply(card)
        }
        try? context.save()
    }

    @MainActor
    private static func insert(rulings: [ScryfallRulingLine], container: ModelContainer) {
        let context = container.mainContext
        for line in rulings {
            guard let oracleID = line.oracleId else { continue }
            context.insert(CardRuling(
                oracleID: oracleID,
                source: line.source ?? "scryfall",
                publishedAt: line.publishedAt ?? "",
                comment: line.comment ?? ""
            ))
        }
        try? context.save()
    }
}
