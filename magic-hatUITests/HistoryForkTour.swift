//
//  HistoryForkTour.swift
//  magic-hatUITests
//
//  Screenshots of the History tab after a bulk add is undone and another
//  bulk add follows it — a fork whose two sides are both "Added n Cards".
//  Written to `TEST_RUNNER_UITEST_SHOT_DIR`; skipped when that isn't set.
//

import XCTest

final class HistoryForkTour: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SHOT_DIR to take screenshots.")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        usleep(800_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func bulkAdd(_ app: XCUIApplication, _ names: [String]) {
        app.tabBars.buttons["Collection"].tap()
        if !app.navigationBars["Test Collection"].exists { app.staticTexts["Test Collection"].tap() }
        let first = app.staticTexts[names[0]].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        for name in names.dropFirst() { app.staticTexts[name].firstMatch.tap() }
        app.buttons["selection-add"].tap()
        let target = app.buttons["Test Collection"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        XCTAssertTrue(app.buttons["selection-done"].waitForNonExistence(timeout: 10), "the add finished and selection ended")
    }

    @MainActor
    func testForkAfterUndoneBulkAdd() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()

        bulkAdd(app, ["Card 0"])
        bulkAdd(app, ["Card 0", "Card 10", "Card 100"])
        app.tabBars.buttons["History"].tap()
        let undo = app.buttons["history-undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        shot("h01-before-undo")
        undo.tap()
        XCTAssertTrue(app.descendants(matching: .any)["history-busy"].waitForNonExistence(timeout: 10))
        shot("h02-undone")
        bulkAdd(app, ["Card 1", "Card 101"])
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        shot("h03-fork")
    }
}
