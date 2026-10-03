import Testing
import Foundation
@testable import magic_hat

/// The activity log: a run's begin, progress and end, a skip dated as a
/// run, persistence across instances, and the status line.
@MainActor
@Suite("DataActivity")
struct DataActivityTests {
    private func defaults() -> UserDefaults {
        let suite = "DataActivityTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func beginProgressEndAndPersist() {
        let d = defaults()
        let log = DataActivity(defaults: d)
        #expect(!log.isAnythingRunning && log.records[.prices] == nil)
        log.begin(.prices, total: 150)
        #expect(log.isRunning(.prices) && log.isAnythingRunning)
        #expect(log.records[.prices]?.finishedAt == nil)
        log.progress(.prices, done: 75)
        #expect(log.running[.prices]?.done == 75 && log.running[.prices]?.total == 150)
        log.end(.prices, count: 150, note: "150 cards")
        #expect(!log.isRunning(.prices))
        #expect(log.records[.prices]?.count == 150 && log.records[.prices]?.note == "150 cards" && log.records[.prices]?.failed == false)
        #expect(log.records[.prices]?.duration != nil)

        let again = DataActivity(defaults: d)
        #expect(again.records[.prices]?.note == "150 cards", "the last run is kept")
        #expect(!again.isAnythingRunning, "a run never persists as running")
    }

    @Test func skipAndFailure() {
        let log = DataActivity(defaults: defaults())
        log.skip(.catalog, note: "Checked · up to date")
        #expect(log.records[.catalog]?.finishedAt != nil && log.records[.catalog]?.count == 0)
        log.begin(.backup)
        log.end(.backup, note: "No space", failed: true)
        #expect(log.records[.backup]?.failed == true)
        #expect(log.progressIsIgnoredWhenNotRunning())
    }

    @Test func statusLines() {
        let now = Date()
        #expect(DataActivityText.status(nil, running: false, now: now) == "Never")
        #expect(DataActivityText.status(nil, running: true, now: now) == "Running…")
        let record = DataActivityRecord(startedAt: now.addingTimeInterval(-7230), finishedAt: now.addingTimeInterval(-7200),
                                        count: 3_846, note: "3,846 cards", failed: false)
        #expect(DataActivityText.status(record, running: false, now: now) == "2 hours ago · 3,846 cards · 30s")
        let skip = DataActivityRecord(startedAt: now.addingTimeInterval(-10), finishedAt: now.addingTimeInterval(-10),
                                      count: 0, note: "Checked · up to date", failed: false)
        #expect(DataActivityText.status(skip, running: false, now: now) == "Just now · Checked · up to date")
        #expect(DataActivityText.duration(0.4) == "under a second")
        #expect(DataActivityText.duration(95) == "2 min")
    }
}

private extension DataActivity {
    func progressIsIgnoredWhenNotRunning() -> Bool {
        progress(.setList, done: 3)
        return running[.setList] == nil
    }
}
