//
//  SyncBarTour.swift
//  magic-hatUITests
//
//  The catalog sync bar rides above the tab bar while a sync runs and
//  leaves with it. Driven by `-uitest-fake-sync` (no
//  network): four seconds of "download", two of "ingest", then idle.
//  Writes PNGs to `TEST_RUNNER_UITEST_SHOT_DIR` when set, for vetting.
//

import XCTest

final class SyncBarTour: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testBarComesAndGoes() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed", "-uitest-fake-sync"]
        app.launch()
        app.tabBars.buttons["Collection"].tap()
        let bar = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Downloading' OR label BEGINSWITH 'Adding'")).firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "the bar shows while downloading")
        shot(app, "sync-01-downloading")
        // The fake sync is idle six seconds after launch; give it ten more.
        sleep(10)
        shot(app, "sync-02-idle")
        XCTAssertFalse(bar.exists, "the bar leaves when the sync ends")
    }
}
