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
        case waitingForWiFi(BulkDataset)
        case downloading(BulkDataset, fraction: Double)
        case ingesting(BulkDataset, done: Int)
        case failed(String)

        var isActive: Bool {
            switch self {
            case .idle, .failed: return false
            default: return true
            }
        }

        /// Whether the status bar should appear. The manifest check runs on
        /// every launch and usually finds nothing to do; flashing a
        /// "Checking…" strip for it looked broken. The first-launch setup
        /// screen still narrates that phase, because there it is the point.
        var showsProgressBar: Bool {
            switch self {
            case .downloading, .ingesting, .waitingForWiFi: return true
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .idle

    /// True once the card catalog has been ingested at least once. Drives
    /// the first-launch setup screen; observable, unlike UserDefaults.
    private(set) var catalogReady: Bool

    /// User opted to download the large catalog over cellular.
    var allowCellular: Bool {
        didSet { defaults.set(allowCellular, forKey: "bulk.allowCellular") }
    }

    private init() {
        catalogReady = UserDefaults.standard.string(forKey: "bulk.version.default_cards") != nil
        allowCellular = UserDefaults.standard.bool(forKey: "bulk.allowCellular")
    }

    /// Test hook: pretend the catalog is present so UI tests skip setup.
    func markCatalogReadyForTesting() { catalogReady = true }

    /// 0...1 for the bar, or nil while indeterminate.
    var fraction: Double? {
        if case .downloading(_, let f) = phase { return f }
        return nil
    }

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .checking: return "Checking card data…"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .downloading(let set, let f): return "Downloading \(set.displayName) — \(Int(f * 100))%"
        case .ingesting(let set, let done): return "Adding \(set.displayName) — \(done.formatted())"
        case .failed(let message): return message
        }
    }

    private let defaults = UserDefaults.standard
    private var isRunning = false

    private func versionKey(_ dataset: BulkDataset) -> String { "bulk.version.\(dataset.rawValue)" }
    private func ingestedAtKey(_ dataset: BulkDataset) -> String { "bulk.ingestedAt.\(dataset.rawValue)" }

    func hasIngested(_ dataset: BulkDataset) -> Bool {
        defaults.string(forKey: versionKey(dataset)) != nil
    }

    /// Whether to take a new build of `dataset`. Never ingested → yes. Same
    /// build as last time → no. Newer build → only if our copy is older than
    /// the dataset's refresh interval; Scryfall rebuilds daily and a 79MB
    /// catalog every day is not worth it when owned-card prices already
    /// refresh via the cheap batched call.
    private func shouldIngest(_ entry: ScryfallBulkEntry, _ dataset: BulkDataset) -> Bool {
        guard let have = defaults.string(forKey: versionKey(dataset)) else { return true }
        guard have != entry.updatedAt else { return false }
        let last = defaults.object(forKey: ingestedAtKey(dataset)) as? Date ?? .distantPast
        let interval = dataset == .rulings
            ? DataPolicy.rulingsRefreshInterval
            : DataPolicy.catalogRefreshInterval
        return Date().timeIntervalSince(last) >= interval
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
                  shouldIngest(entry, dataset)
            else { continue }

            do {
                let file = try await download(uri, dataset: dataset)
                defer { try? FileManager.default.removeItem(at: file) }
                try await ingest(file, dataset: dataset, container: container)
                defaults.set(entry.updatedAt, forKey: versionKey(dataset))
                defaults.set(Date(), forKey: ingestedAtKey(dataset))
                if dataset == .defaultCards { catalogReady = true }
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
        // Rulings are ~5MB — fine anywhere. The catalog waits for Wi-Fi unless
        // the user has said otherwise, and says so instead of sitting at 0%.
        let mayUseCellular = dataset == .rulings || allowCellular
        if !mayUseCellular {
            let network = NetworkMonitor.shared
            while network.isMetered && !allowCellular {
                phase = .waitingForWiFi(dataset)
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
            }
        }
        phase = .downloading(dataset, fraction: 0)

        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = dataset == .rulings || allowCellular
        config.allowsConstrainedNetworkAccess = dataset == .rulings || allowCellular
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
        try await BulkIngester.ingest(file: file, dataset: dataset, container: container) { done in
            Task { @MainActor in
                CatalogSyncController.shared.phase = .ingesting(dataset, done: done)
            }
        }
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
