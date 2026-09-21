//
//  CatalogSyncController.swift
//  magic-hat
//
//  Downloads and ingests Scryfall's bulk data: every English printing, plus
//  all rulings. Two phases per dataset, reported separately because they
//  progress and fail differently.
//
//   1. Download — a real URLSessionDownloadTask, so bytes land in a file
//      rather than in memory and the system can schedule the transfer.
//      Expensive/constrained networks are refused, so a ~79MB catalog waits
//      for Wi-Fi instead of eating a data plan.
//   2. Ingest — the file is pulled through GzipLineReader on a background
//      task, decoded in batches, and each batch is handed to the main actor
//      to write. SwiftData models are main-actor-bound in this project, so
//      the split keeps JSON parsing off the main thread while writes stay
//      where they must be. Memory stays flat: one batch at a time.
//
//  Re-running is cheap: the manifest's `updatedAt` is compared with what we
//  last ingested, and nothing downloads if it hasn't changed.
//

import Foundation
import SwiftData

@MainActor
@Observable
final class CatalogSyncController {
    static let shared = CatalogSyncController()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading(BulkDataset, fraction: Double)
        case ingesting(BulkDataset, done: Int)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .failed: return false
            default: return true
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// 0...1 for the bar, or nil while indeterminate.
    var fraction: Double? {
        if case .downloading(_, let f) = phase { return f }
        return nil
    }

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .checking: return "Checking card data…"
        case .downloading(let set, let f): return "Downloading \(set.displayName) — \(Int(f * 100))%"
        case .ingesting(let set, let done): return "Adding \(set.displayName) — \(done.formatted())"
        case .failed(let message): return message
        }
    }

    private let defaults = UserDefaults.standard
    private var isRunning = false
    private var batchSize: Int { 500 }

    private func versionKey(_ dataset: BulkDataset) -> String { "bulk.version.\(dataset.rawValue)" }

    func hasIngested(_ dataset: BulkDataset) -> Bool {
        defaults.string(forKey: versionKey(dataset)) != nil
    }

    /// Ingests any dataset that is missing or stale. Safe to call on launch.
    func syncIfNeeded(container: ModelContainer) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; if case .failed = phase {} else { phase = .idle } }

        phase = .checking
        let manifest: [ScryfallBulkEntry]
        do {
            manifest = try await ScryfallBulkClient.shared.manifest()
        } catch {
            phase = .failed("Couldn't reach Scryfall.")
            return
        }

        // Rulings first: small, and it lights up the Rulings tab immediately.
        for dataset in [BulkDataset.rulings, .defaultCards] {
            guard let entry = manifest.first(where: { $0.type == dataset.rawValue }),
                  let uriString = entry.jsonlDownloadURI,
                  let uri = URL(string: uriString),
                  defaults.string(forKey: versionKey(dataset)) != entry.updatedAt
            else { continue }

            do {
                let file = try await download(uri, dataset: dataset)
                defer { try? FileManager.default.removeItem(at: file) }
                try await ingest(file, dataset: dataset, container: container)
                defaults.set(entry.updatedAt, forKey: versionKey(dataset))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed("Couldn't add \(dataset.displayName).")
                return
            }
        }
    }

    // MARK: Download

    private func download(_ url: URL, dataset: BulkDataset) async throws -> URL {
        phase = .downloading(dataset, fraction: 0)

        let config = URLSessionConfiguration.default
        // Large and not urgent: don't spend the user's cellular data on it.
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("MagicHat/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let observer = DownloadProgressObserver { [weak self] fraction in
            Task { @MainActor in self?.phase = .downloading(dataset, fraction: fraction) }
        }
        let (temporary, _) = try await session.download(for: request, delegate: observer)

        // The temp file is only guaranteed for the life of this call.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(dataset.rawValue)-\(UUID().uuidString).jsonl.gz")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: Ingest

    private func ingest(_ file: URL, dataset: BulkDataset, container: ModelContainer) async throws {
        phase = .ingesting(dataset, done: 0)
        let size = batchSize

        // Parsing happens here, off the main actor; each decoded batch is
        // awaited onto the main actor to be written, which also throttles the
        // reader — it can't run ahead and pile up in memory.
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
                        await MainActor.run { Self.upsert(cards: cards, container: container) }
                    }
                case .rulings:
                    let rulings = lines
                        .compactMap { try? decoder.decode(ScryfallRulingLine.self, from: $0) }
                        .filter { $0.oracleId != nil }
                    if !rulings.isEmpty {
                        await MainActor.run { Self.insert(rulings: rulings, container: container) }
                    }
                }

                done += lines.count
                // Report sparsely: this drives a view, and at one update per
                // batch it would redraw ten times a second for minutes.
                if done % (size * 10) == 0 || lines.count < size {
                    let progress = done
                    await MainActor.run {
                        CatalogSyncController.shared.phase = .ingesting(dataset, done: progress)
                    }
                }
            }
        }.value
    }

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

/// Bridges URLSession's delegate progress into a closure.
private final class DownloadProgressObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async download(for:delegate:) return value.
    }
}
