//
//  CatalogSyncController.swift
//  magic-hat
//
//  Downloads and ingests Scryfall's bulk data: every English printing, plus
//  all rulings. Two phases per dataset, reported separately because they
//  progress and fail differently.
//
//   1. Download — a background URLSession, so the transfer belongs to the
//      system: it carries on if the app is suspended or the process is
//      dropped, and the finished file is handed back through the app
//      delegate when the app is relaunched for it. A file that arrives
//      while nobody is waiting is parked in Caches/bulk-pending and
//      ingested on the next foreground. Expensive/constrained networks are
//      refused per request, so a ~79MB catalog waits for Wi-Fi instead of
//      eating a data plan.
//   2. Ingest — the file is pulled through GzipLineReader on a background
//      task, decoded in batches, and each batch is written by
//      CardMetaWriter on its own queue. Memory stays flat: one batch at a
//      time.
//
//  When to run which: the first launch downloads and ingests in the
//  foreground, attended, behind the setup screen. Once a catalog exists, a
//  newer build is *never* fetched at launch — 79MB while the user wants
//  the app is the wrong moment. Instead a BGProcessingTask is scheduled,
//  and the system runs the refresh when the phone is on power and Wi-Fi.
//  Re-running is cheap: the manifest's `updatedAt` is compared with what we
//  last ingested, and nothing downloads if it hasn't changed.
//

import Foundation
import os
import SwiftData
import BackgroundTasks
import UIKit

@MainActor
@Observable
final class CatalogSyncController {
    static let shared = CatalogSyncController()
    static let refreshTaskIdentifier = "com.griffin.magic-hat.catalog-refresh"
    static let sessionIdentifier = "com.griffin.magic-hat.bulk"

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

    #if DEBUG
    /// `-uitest-fake-sync`: walks the phases a real download would, with
    /// no network, so a UI test can see the sync bar come and go.
    func simulateSyncForTesting() {
        Task { @MainActor in
            for i in 1...4 {
                phase = .downloading(.defaultCards, fraction: Double(i) / 5)
                try? await Task.sleep(for: .seconds(1))
            }
            phase = .ingesting(.defaultCards, done: 12_000)
            try? await Task.sleep(for: .seconds(2))
            phase = .idle
        }
    }
    #endif

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
    private var lastManifestCheck: Date?
    /// The container, attached at launch, for runs that start without a
    /// scene (a background refresh, a relaunch for a finished download).
    private var container: ModelContainer?
    /// Callers awaiting a transfer, by dataset. Absent when the transfer
    /// finishes with nobody waiting (the app was relaunched for it).
    private var waiters: [BulkDataset: CheckedContinuation<URL, Error>] = [:]
    private var backgroundSessionCompletion: (() -> Void)?
    private var refreshWork: Task<Void, Never>?

    private func versionKey(_ dataset: BulkDataset) -> String { "bulk.version.\(dataset.rawValue)" }
    private func ingestedAtKey(_ dataset: BulkDataset) -> String { "bulk.ingestedAt.\(dataset.rawValue)" }
    private func pendingVersionKey(_ dataset: BulkDataset) -> String { "bulk.pendingVersion.\(dataset.rawValue)" }

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

    // MARK: Checking by hand (Settings)

    /// What a manual check found. The check compares builds only: the
    /// weekly interval is for automatic refreshes, and someone who asks
    /// wants the newest build Scryfall has.
    enum UpdateCheck: Equatable {
        case upToDate
        /// Newer builds of these datasets, and their download size.
        case available(bytes: Int?, builtAt: Date?)
        case failed(String)
    }

    private(set) var lastCheck: UpdateCheck?
    private(set) var isCheckingForUpdates = false

    /// When `dataset` was last ingested on this device.
    func lastIngested(_ dataset: BulkDataset) -> Date? {
        defaults.object(forKey: ingestedAtKey(dataset)) as? Date
    }

    /// When Scryfall built the copy we have ("2026-09-20T09:02:48.126+00:00").
    func builtAt(_ dataset: BulkDataset) -> Date? {
        defaults.string(forKey: versionKey(dataset)).flatMap(Self.parseBuildDate)
    }

    /// "Oct 2" for the activity log's note.
    nonisolated static func buildLabel(_ raw: String) -> String {
        parseBuildDate(raw)?.formatted(date: .abbreviated, time: .omitted) ?? raw
    }

    nonisolated static func parseBuildDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    /// Looks at the manifest and says whether anything newer exists,
    /// downloading nothing.
    @discardableResult
    func checkForUpdates() async -> UpdateCheck {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }
        let result: UpdateCheck
        do {
            let manifest = try await ScryfallBulkClient.shared.manifest()
            lastManifestCheck = Date()
            let newer = manifestEntries(manifest).filter { entry, dataset in
                defaults.string(forKey: versionKey(dataset)) != entry.updatedAt
            }
            if newer.isEmpty {
                result = .upToDate
            } else {
                let bytes = newer.compactMap(\.entry.compressedSize).reduce(0, +)
                let catalog = newer.first { $0.dataset == .defaultCards }?.entry ?? newer[0].entry
                result = .available(bytes: bytes > 0 ? bytes : nil, builtAt: Self.parseBuildDate(catalog.updatedAt))
            }
        } catch {
            result = .failed("Couldn't reach Scryfall.")
        }
        lastCheck = result
        return result
    }

    /// Downloads and ingests every dataset whose build differs from ours,
    /// now, in the foreground — the bar narrates it and the app stays
    /// usable. The cellular rule still applies: it waits for Wi-Fi, and
    /// says so, unless the user has allowed cellular.
    func updateNow(container: ModelContainer) async {
        self.container = container
        guard !isRunning else { return }
        isRunning = true
        defer {
            isRunning = false
            if case .failed = phase {} else { phase = .idle }
        }
        phase = .checking
        guard let manifest = try? await ScryfallBulkClient.shared.manifest() else {
            phase = .failed("Couldn't reach Scryfall.")
            return
        }
        lastManifestCheck = Date()
        for (entry, dataset) in manifestEntries(manifest)
            where defaults.string(forKey: versionKey(dataset)) != entry.updatedAt {
            guard let uri = entry.jsonlDownloadURI.flatMap(URL.init(string:)) else { continue }
            do {
                let file = try await download(uri, dataset: dataset, version: entry.updatedAt)
                try await ingest(file, dataset: dataset, version: entry.updatedAt, container: container)
            } catch is CancellationError {
                return
            } catch {
                phase = .failed("Couldn't add \(dataset.displayName).")
                return
            }
        }
        lastCheck = .upToDate
    }

    /// The manifest's entries for the datasets we keep, rulings first.
    private func manifestEntries(_ manifest: [ScryfallBulkEntry]) -> [(entry: ScryfallBulkEntry, dataset: BulkDataset)] {
        [BulkDataset.rulings, .defaultCards].compactMap { dataset in
            manifest.first { $0.type == dataset.rawValue }.map { ($0, dataset) }
        }
    }

    // MARK: Launch

    func attach(container: ModelContainer) {
        self.container = container
    }

    /// Must run before the app finishes launching — the app delegate does.
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in CatalogSyncController.shared.handleRefresh(task) }
        }
    }

    /// The system relaunched us for a finished background download: build
    /// the session again under the same identifier so the delegate receives
    /// the file, and keep the completion handler for when it has.
    func reconnectBackgroundSession(completion: @escaping () -> Void) {
        backgroundSessionCompletion = completion
        _ = session
    }

    /// Ingests any dataset that is missing or stale. Safe to call on launch.
    /// A first-launch catalog downloads and ingests here, in the
    /// foreground; a refresh of one we already have is left to the system.
    func syncIfNeeded(container: ModelContainer) async {
        self.container = container
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; if case .failed = phase {} else { phase = .idle } }

        sweepStrayFiles()
        await ingestPending(container: container)

        phase = .checking
        let manifest: [ScryfallBulkEntry]
        do {
            manifest = try await ScryfallBulkClient.shared.manifest()
        } catch {
            phase = .failed("Couldn't reach Scryfall.")
            DataActivity.shared.skip(.catalog, note: "Couldn't reach Scryfall")
            return
        }
        lastManifestCheck = Date()

        // Rulings first: small, and it lights up the Rulings tab immediately.
        for dataset in [BulkDataset.rulings, .defaultCards] {
            guard let entry = manifest.first(where: { $0.type == dataset.rawValue }),
                  let uriString = entry.jsonlDownloadURI,
                  let uri = URL(string: uriString),
                  shouldIngest(entry, dataset)
            else { continue }

            if hasIngested(dataset) {
                scheduleRefresh()
                DataActivity.shared.skip(Self.activityTask(dataset), note: "Checked · a newer build waits for charging on Wi-Fi")
                continue
            }
            do {
                let file = try await download(uri, dataset: dataset, version: entry.updatedAt)
                try await ingest(file, dataset: dataset, version: entry.updatedAt, container: container)
            } catch is CancellationError {
                DataActivity.shared.end(Self.activityTask(dataset), note: "Stopped", failed: true)
                return
            } catch {
                phase = .failed("Couldn't add \(dataset.displayName).")
                DataActivity.shared.end(Self.activityTask(dataset), note: "Couldn't add \(dataset.displayName)", failed: true)
                return
            }
        }
        for dataset in [BulkDataset.rulings, .defaultCards] where hasIngested(dataset) {
            let entry = manifest.first { $0.type == dataset.rawValue }
            if let entry, !shouldIngest(entry, dataset), !DataActivity.shared.isRunning(Self.activityTask(dataset)) {
                DataActivity.shared.skip(Self.activityTask(dataset), note: "Checked · up to date")
            }
        }
    }

    /// On return to the foreground: take whatever a background download
    /// delivered, and re-check the manifest if it has been a while.
    func resumeIfNeeded(container: ModelContainer) async {
        self.container = container
        guard !isRunning else { return }
        let hasPending = BulkDataset.allCases.contains { FileManager.default.fileExists(atPath: Self.pendingURL(for: $0).path) }
        let stale = lastManifestCheck.map { Date().timeIntervalSince($0) > 3600 } ?? true
        if hasPending || stale {
            await syncIfNeeded(container: container)
        }
    }

    // MARK: Background refresh

    private func scheduleRefresh() {
        // Settings can leave the catalog as it is until Check for Updates.
        guard AppSettings.autoCatalogRefresh else { return }
        let request = BGProcessingTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        // Fails on the simulator and when the identifier isn't permitted;
        // neither is worth more than a skipped refresh.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The system's moment for the big download: on power, on Wi-Fi, in
    /// the background. Whatever doesn't finish before the task expires is
    /// picked up later — the transfer keeps going on its own, and a file
    /// already landed is ingested on the next foreground.
    private func handleRefresh(_ task: BGProcessingTask) {
        guard let container, !isRunning else { task.setTaskCompleted(success: false); return }
        let work = Task { @MainActor in
            let ok = await self.runRefresh(container: container)
            task.setTaskCompleted(success: ok)
        }
        refreshWork = work
        task.expirationHandler = { work.cancel() }
    }

    private func runRefresh(container: ModelContainer) async -> Bool {
        isRunning = true
        defer { isRunning = false; if case .failed = phase {} else { phase = .idle } }
        await ingestPending(container: container)
        guard let manifest = try? await ScryfallBulkClient.shared.manifest() else { return false }
        lastManifestCheck = Date()
        for dataset in [BulkDataset.rulings, .defaultCards] {
            guard let entry = manifest.first(where: { $0.type == dataset.rawValue }),
                  let uriString = entry.jsonlDownloadURI,
                  let uri = URL(string: uriString),
                  shouldIngest(entry, dataset)
            else { continue }
            do {
                let file = try await download(uri, dataset: dataset, version: entry.updatedAt)
                try await ingest(file, dataset: dataset, version: entry.updatedAt, container: container)
            } catch {
                return false
            }
        }
        return true
    }

    // MARK: Download

    /// Caches/bulk-pending/<dataset>.jsonl.gz — where a finished transfer
    /// waits until it is ingested.
    nonisolated static func pendingURL(for dataset: BulkDataset) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("bulk-pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(dataset.rawValue).jsonl.gz")
    }

    @ObservationIgnored private lazy var sessionDelegate = BulkDownloadDelegate(controller: self)

    /// One background session for the app; its identifier is what lets the
    /// system hand a finished file back after a relaunch.
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        config.isDiscretionary = false
        return URLSession(configuration: config, delegate: sessionDelegate, delegateQueue: nil)
    }()

    private func download(_ url: URL, dataset: BulkDataset, version: String) async throws -> URL {
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
        DataActivity.shared.begin(Self.activityTask(dataset))
        defaults.set(version, forKey: pendingVersionKey(dataset))

        // A transfer already in flight (we were relaunched mid-download):
        // wait for that one rather than starting it over.
        let inFlight = await session.allTasks.first { $0.taskDescription == dataset.rawValue && $0.state == .running }
        if let inFlight {
            return try await completion(of: inFlight, dataset: dataset)
        }

        var request = URLRequest(url: url)
        request.setValue("MagicHat/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.allowsExpensiveNetworkAccess = mayUseCellular
        request.allowsConstrainedNetworkAccess = mayUseCellular
        let task = session.downloadTask(with: request)
        task.taskDescription = dataset.rawValue
        return try await completion(of: task, dataset: dataset)
    }

    /// Waits for the transfer. Cancelling the waiting task (a background
    /// refresh that ran out of time) stops the wait, not the transfer: it
    /// finishes on its own and is ingested from bulk-pending later.
    private func completion(of task: URLSessionTask, dataset: BulkDataset) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[dataset] = continuation
                task.resume()
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: dataset)?.resume(throwing: CancellationError()) }
        }
    }

    // Delegate callbacks, on the main actor.

    fileprivate func downloadProgressed(_ dataset: BulkDataset, fraction: Double) {
        if case .downloading(dataset, _) = phase { phase = .downloading(dataset, fraction: fraction) }
        DataActivity.shared.progress(Self.activityTask(dataset), done: Int(fraction * 100), total: 100)
    }

    fileprivate func downloadFinished(_ dataset: BulkDataset, file: URL) {
        if let waiter = waiters.removeValue(forKey: dataset) {
            waiter.resume(returning: file)
        }
        // Nobody waiting: the file sits in bulk-pending for the next
        // foreground (resumeIfNeeded) or launch (syncIfNeeded).
    }

    fileprivate func downloadFailed(_ dataset: BulkDataset, error: Error) {
        defaults.removeObject(forKey: pendingVersionKey(dataset))
        if let waiter = waiters.removeValue(forKey: dataset) {
            waiter.resume(throwing: error)
        }
    }

    fileprivate func backgroundSessionEventsFinished() {
        backgroundSessionCompletion?()
        backgroundSessionCompletion = nil
    }

    // MARK: Ingest

    private static func activityTask(_ dataset: BulkDataset) -> DataTask { dataset == .rulings ? .rulings : .catalog }

    private func ingest(_ file: URL, dataset: BulkDataset, version: String, container: ModelContainer) async throws {
        phase = .ingesting(dataset, done: 0)
        let activity = DataActivity.shared
        let task = Self.activityTask(dataset)
        if !activity.isRunning(task) { activity.begin(task) }
        // The row count the ingest reports last, read back here on the
        // main actor; the progress closure is Sendable and may not mutate.
        let counter = OSAllocatedUnfairLock(initialState: 0)
        do {
            try await BulkIngester.ingest(file: file, dataset: dataset, container: container) { done in
                counter.withLock { $0 = done }
                Task { @MainActor in
                    CatalogSyncController.shared.phase = .ingesting(dataset, done: done)
                    DataActivity.shared.progress(task, done: done)
                }
            }
        } catch {
            activity.end(task, count: counter.withLock { $0 }, note: "Couldn't add \(dataset.displayName)", failed: true)
            throw error
        }
        let rows = counter.withLock { $0 }
        activity.end(task, count: rows, note: "\(rows.formatted()) \(dataset == .rulings ? "rulings" : "cards") · build \(Self.buildLabel(version))")
        defaults.set(version, forKey: versionKey(dataset))
        defaults.set(Date(), forKey: ingestedAtKey(dataset))
        defaults.removeObject(forKey: pendingVersionKey(dataset))
        try? FileManager.default.removeItem(at: file)
        if dataset == .defaultCards { catalogReady = true }
    }

    /// Files a background transfer delivered while nobody was waiting.
    private func ingestPending(container: ModelContainer) async {
        for dataset in [BulkDataset.rulings, .defaultCards] {
            let file = Self.pendingURL(for: dataset)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard let version = defaults.string(forKey: pendingVersionKey(dataset)) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            do {
                try await ingest(file, dataset: dataset, version: version, container: container)
            } catch is CancellationError {
                return
            } catch {
                // Unreadable: drop it and let the manifest decide again.
                try? FileManager.default.removeItem(at: file)
                defaults.removeObject(forKey: pendingVersionKey(dataset))
            }
        }
    }

    /// Earlier builds moved downloads into tmp/ and only cleaned up on a
    /// successful run; a process death mid-ingest left 80MB behind.
    private func sweepStrayFiles() {
        Task.detached(priority: .utility) {
            let tmp = FileManager.default.temporaryDirectory
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
            for name in names where name.hasSuffix(".jsonl.gz") {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }
}

/// The background session's delegate. Moves a finished file out of the
/// system's temporary location synchronously — it is only valid for the
/// life of the callback — then tells the controller on the main actor.
private nonisolated final class BulkDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private unowned let controller: CatalogSyncController
    private var lastReported: [String: Double] = [:]

    init(controller: CatalogSyncController) {
        self.controller = controller
    }

    private func dataset(of task: URLSessionTask) -> BulkDataset? {
        task.taskDescription.flatMap(BulkDataset.init(rawValue:))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let dataset = dataset(of: downloadTask) else { return }
        // At most once per half a percent: the delegate fires per received
        // chunk, thousands of times over an 80MB file, and each report is a
        // main-actor hop that re-renders the setup screen or the bar.
        let fraction = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)
        guard fraction - (lastReported[dataset.rawValue] ?? -1) >= 0.005 || fraction >= 1 else { return }
        lastReported[dataset.rawValue] = fraction
        Task { @MainActor in self.controller.downloadProgressed(dataset, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dataset = dataset(of: downloadTask) else { return }
        let destination = CatalogSyncController.pendingURL(for: dataset)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in self.controller.downloadFailed(dataset, error: error) }
            return
        }
        Task { @MainActor in self.controller.downloadFinished(dataset, file: destination) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let dataset = dataset(of: task) else { return }
        Task { @MainActor in self.controller.downloadFailed(dataset, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.controller.backgroundSessionEventsFinished() }
    }
}
