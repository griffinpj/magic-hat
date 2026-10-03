//
//  CollectionsTour.swift
//  magic-hatUITests
//
//  Screenshots of the Collections tab for vetting its design, on the real
//  store (`-uitest-real`, kept from a RealCollectionTests run) when
//  `TEST_RUNNER_UITEST_REAL=1`, else on the seed with a list added.
//  Written to `TEST_RUNNER_UITEST_SHOT_DIR`; skipped when that isn't set.
//

import XCTest

final class CollectionsTour: XCTestCase {
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
        usleep(900_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testCollectionsTab() {
        let app = XCUIApplication()
        let real = ProcessInfo.processInfo.environment["UITEST_REAL"] == "1"
        app.launchArguments = [real ? "-uitest-real" : "-uitest-seed"]
        if real, let csv = ProcessInfo.processInfo.environment["UITEST_CSV"] { app.launchEnvironment["UITEST_IMPORT_CSV"] = csv }
        app.launch()
        if !real {
            app.buttons["collections-menu"].tap()
            app.buttons["new-list-menu"].tap()
            app.alerts.textFields.firstMatch.typeText("Wants")
            app.alerts.buttons["Create"].tap()
            XCTAssertTrue(app.navigationBars["Wants"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons["collections-menu"].tap()
            app.buttons["new-collection-menu"].tap()
            app.alerts.textFields.firstMatch.typeText("Trade Binder")
            app.alerts.buttons["Create"].tap()
            XCTAssertTrue(app.navigationBars["Trade Binder"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.buttons["collection-all"].waitForExistence(timeout: 60))
        sleep(real ? 12 : 2)
        shot(real ? "k01-collections-real" : "k01-collections-seed")
        app.swipeUp()
        shot(real ? "k02-collections-real-down" : "k02-collections-seed-down")
    }
}
