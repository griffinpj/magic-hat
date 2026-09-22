//
//  BulkIngester.swift
//  magic-hat
//
//  Turns a downloaded Scryfall bulk file (`.jsonl.gz`) into rows in the
//  store. Split out of CatalogSyncController so it can be run against a
//  fixture slice in tests, with no network and no UserDefaults.
//
//  Parsing runs on a detached task; each decoded batch is awaited onto
//  CardMetaWriter, a ModelActor with its own background context, so the
//  112k-row catalog and the rulings never touch the main thread. Awaiting
//  each batch also throttles the reader, so memory stays flat regardless
//  of file size.
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
        let writer = await CardMetaWriter.shared(for: container)
        // .background, not .utility: the system throttles background I/O,
        // and a catalog or rulings ingest right after launch was starving
        // the first keyboard presentation's disk reads for seconds.
        try await Task.detached(priority: .background) {
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
                        try await writer.apply(cards: cards, linkEntries: false)
                    }
                case .rulings:
                    let rulings = lines
                        .compactMap { try? decoder.decode(ScryfallRulingLine.self, from: $0) }
                        .filter { $0.oracleId != nil }
                    if !rulings.isEmpty {
                        try await writer.insert(rulings: rulings)
                    }
                }

                done += lines.count
                if done % (size * 10) == 0 || lines.count < size {
                    progress(done)
                }
            }
        }.value
    }
}
