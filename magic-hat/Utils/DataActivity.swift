//
//  DataActivity.swift
//  magic-hat
//
//  One place that knows what the app loads, when it last did, and what is
//  running now — the catalog, rulings, card data, prices, backups, the
//  analysis signal lists, the search vocabularies — so Settings can show
//  it (`DataActivityView`) and nothing runs in the dark. Each loader
//  calls `begin` / `progress` / `end`; the last run of every kind is
//  kept in UserDefaults (a few hundred bytes), the current run in memory.
//
//  Observing: the whole object is `@Observable`, and only Settings reads
//  it, so a loader's progress reports cost nothing anywhere else. Loaders
//  report at most a few times a second (hydration per 75-card batch, the
//  catalog once per half a percent), which is fine for one screen.
//

import Foundation
import Observation

/// Every kind of load the app does on its own.
nonisolated enum DataTask: String, CaseIterable, Codable, Sendable, Identifiable {
    case catalog, rulings, cardData, prices, backup, analysisSignals, vocabularies, setList

    var id: String { rawValue }

    var title: String {
        switch self {
        case .catalog: return "Card Catalog"
        case .rulings: return "Rulings"
        case .cardData: return "Card Data"
        case .prices: return "Prices"
        case .backup: return "Backup"
        case .analysisSignals: return "Analysis Signals"
        case .vocabularies: return "Search Vocabularies"
        case .setList: return "Set List"
        }
    }

    var systemImage: String {
        switch self {
        case .catalog: return "books.vertical"
        case .rulings: return "text.book.closed"
        case .cardData: return "square.stack.3d.up"
        case .prices: return "dollarsign.circle"
        case .backup: return "externaldrive"
        case .analysisSignals: return "chart.bar.xaxis"
        case .vocabularies: return "character.book.closed"
        case .setList: return "square.grid.3x3"
        }
    }

    /// What it is, in a line.
    var summary: String {
        switch self {
        case .catalog: return "Every printing from Scryfall (~80 MB), so cards, imports and rulings work offline."
        case .rulings: return "Scryfall's rulings (~5 MB) for the detail screen's Rulings tab."
        case .cardData: return "Images, prices, rarity and text for the cards you own, 75 per request."
        case .prices: return "Market prices for owned cards, re-fetched through the same batched request."
        case .backup: return "A zip of your collections, decks, lists and History."
        case .analysisSignals: return "Scryfall's game-changer and tag lists the deck analysis reads."
        case .vocabularies: return "Card types, keywords and artists for the search filters."
        case .setList: return "Every set, for the Sets browser and the filters."
        }
    }

    /// When it runs, in a line. Lives here rather than in each controller
    /// so the screen can say it without asking eight objects.
    @MainActor var schedule: String {
        switch self {
        case .catalog:
            return AppSettings.autoCatalogRefresh
                ? "First launch; then weekly while charging on Wi-Fi, or from Check for Updates."
                : "First launch; then only from Check for Updates."
        case .rulings: return "With the catalog, weekly."
        case .cardData: return "After an import, when a collection is opened, and for cards that scroll into view."
        case .prices:
            switch AppSettings.priceRefresh {
            case .manual: return "Only from Refresh Prices Now."
            case let cadence: return "\(cadence.label), on launch and when a collection is opened."
            }
        case .backup:
            switch BackupScheduler.shared.frequency {
            case .off: return "Off."
            case let f: return "\(f.label), eight seconds after the app comes to the front."
            }
        case .analysisSignals: return "Game changers daily, tag lists weekly, a page at a time behind your own searches."
        case .vocabularies: return "Weekly, the first time the search filters are opened."
        case .setList: return "Daily, when the Sets browser or a set filter is opened; pull to refresh forces it."
        }
    }
}

/// The last run of one kind of load.
nonisolated struct DataActivityRecord: Codable, Hashable, Sendable {
    var startedAt: Date
    var finishedAt: Date?
    /// Items handled: cards, rows, bytes — whatever the loader counts.
    var count: Int
    /// What it did, in a few words ("3,846 cards", "up to date", "skipped: on cellular").
    var note: String
    var failed: Bool

    var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }
}

@MainActor
@Observable
final class DataActivity {
    static let shared = DataActivity()

    /// The last run per task, as persisted.
    private(set) var records: [DataTask: DataActivityRecord] = [:]
    /// What is running now, with its progress (done, total) when known.
    private(set) var running: [DataTask: (done: Int, total: Int?)] = [:]

    private let defaults: UserDefaults
    private static let key = "data.activity"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: DataActivityRecord].self, from: data) {
            for (raw, record) in stored { if let task = DataTask(rawValue: raw) { records[task] = record } }
        }
    }

    /// Until when Scryfall traffic is held after a 429 (see RateLimiter);
    /// nil when nothing is held. Shown so a stalled load has a reason.
    private(set) var scryfallPausedUntil: Date?

    var isAnythingRunning: Bool { !running.isEmpty }

    func scryfallPaused(until date: Date) {
        if let current = scryfallPausedUntil, current > date { return }
        scryfallPausedUntil = date
    }

    func isRunning(_ task: DataTask) -> Bool { running[task] != nil }

    /// A run starts. A loader that skips (nothing to do) records with
    /// `skip` instead, so "last ran" stays honest.
    func begin(_ task: DataTask, total: Int? = nil) {
        running[task] = (0, total)
        records[task] = DataActivityRecord(startedAt: Date(), finishedAt: nil, count: 0, note: "Running", failed: false)
    }

    func progress(_ task: DataTask, done: Int, total: Int? = nil) {
        guard let current = running[task] else { return }
        running[task] = (done, total ?? current.total)
    }

    /// A run ends; `count` and `note` describe what it did.
    func end(_ task: DataTask, count: Int = 0, note: String, failed: Bool = false) {
        running[task] = nil
        var record = records[task] ?? DataActivityRecord(startedAt: Date(), finishedAt: nil, count: 0, note: "", failed: false)
        record.finishedAt = Date()
        record.count = count
        record.note = note
        record.failed = failed
        records[task] = record
        persist()
    }

    /// A check that found nothing to do: dated, so the screen can say
    /// "checked 2 hours ago · up to date".
    func skip(_ task: DataTask, note: String) {
        let now = Date()
        records[task] = DataActivityRecord(startedAt: now, finishedAt: now, count: 0, note: note, failed: false)
        persist()
    }

    private func persist() {
        var out: [String: DataActivityRecord] = [:]
        for (task, record) in records where record.finishedAt != nil { out[task.rawValue] = record }
        if let data = try? JSONEncoder().encode(out) { defaults.set(data, forKey: Self.key) }
    }

    #if DEBUG
    /// Tests and the seeded tour: a known log.
    func reset() {
        records = [:]
        running = [:]
        defaults.removeObject(forKey: Self.key)
    }

    /// The seeded tour: a log with something in every state — finished,
    /// skipped, failed, running — so the screen can be vetted by eye.
    func seedForTesting() {
        reset()
        let now = Date()
        func done(_ task: DataTask, ago: TimeInterval, took: TimeInterval, count: Int, note: String, failed: Bool = false) {
            records[task] = DataActivityRecord(startedAt: now.addingTimeInterval(-ago - took), finishedAt: now.addingTimeInterval(-ago),
                                               count: count, note: note, failed: failed)
        }
        done(.catalog, ago: 3 * 86_400, took: 95, count: 112_000, note: "112,000 cards · build Sep 29")
        done(.rulings, ago: 3 * 86_400, took: 12, count: 170_000, note: "170,000 rulings · build Sep 29")
        done(.cardData, ago: 2 * 3600, took: 41, count: 3_846, note: "3,846 cards")
        done(.backup, ago: 86_400, took: 2, count: 1_200_000, note: "1.2 MB · iCloud Drive")
        done(.analysisSignals, ago: 6 * 3600, took: 4, count: 58, note: "58 game changers")
        done(.vocabularies, ago: 5 * 86_400, took: 1, count: 12_400, note: "640 types, 300 keywords, 11,460 artists")
        done(.setList, ago: 7200, took: 1, count: 1_050, note: "1,050 sets")
        records[.prices] = DataActivityRecord(startedAt: now.addingTimeInterval(-20), finishedAt: nil, count: 0, note: "Running", failed: false)
        running[.prices] = (1_240, 3_846)
    }
    #endif
}
