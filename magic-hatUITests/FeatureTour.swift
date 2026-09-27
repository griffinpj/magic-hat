//
//  FeatureTour.swift
//  magic-hatUITests
//
//  Like ScreenshotTour, not a test of behaviour: the newer screens —
//  Settings, About, Backup, History's guide, lists, selection, folders,
//  Sets, Scan, the viewer's flip and quick add — plus the main screens in
//  landscape, written as PNGs to `TEST_RUNNER_UITEST_SHOT_DIR` for vetting
//  by eye. Skipped when that isn't set.
//

import XCTest

final class FeatureTour: XCTestCase {
    private var dir: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SHOT_DIR to take screenshots.")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        usleep(700_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testFeatureTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()

        // Settings, About, Backup.
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        shot("f01-collections")
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        shot("f02-settings")
        app.swipeUp()
        shot("f02b-settings-scrolled")
        app.buttons["settings-backup"].tap()
        XCTAssertTrue(app.navigationBars["Backup & Restore"].waitForExistence(timeout: 5))
        shot("f03-backup")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings-about"].tap()
        XCTAssertTrue(app.staticTexts["about-version"].waitForExistence(timeout: 5))
        shot("f04-about")
        app.buttons["about-disclaimer"].tap()
        shot("f04b-disclaimer")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["settings-done"].tap()

        // A list, and the tab with it.
        app.buttons["collections-menu"].tap()
        app.buttons["new-list-menu"].tap()
        app.alerts.textFields.firstMatch.typeText("Wishlist")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Wishlist"].waitForExistence(timeout: 5))
        shot("f05-empty-list")
        app.navigationBars["Wishlist"].buttons.firstMatch.tap()

        // Selection in the collection.
        app.staticTexts["Test Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 0"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["collection-more"].tap()
        shot("f06-collection-menu")
        app.buttons["collection-select"].tap()
        app.staticTexts["Card 0"].firstMatch.tap()
        app.staticTexts["Card 10"].firstMatch.tap()
        app.staticTexts["Card 100"].firstMatch.tap()
        shot("f07-selecting")
        app.buttons["selection-buy"].tap()
        shot("f07b-buy-menu")
        app.tap()
        app.buttons["selection-done"].tap()

        // The viewer: quick add menu, then landscape.
        app.staticTexts["Card 101"].firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer-add"].waitForExistence(timeout: 5))
        shot("f08-viewer")
        app.buttons["viewer-add"].press(forDuration: 1.0)
        shot("f09-quick-add-menu")
        app.buttons["Wishlist"].firstMatch.tap()
        shot("f09b-quick-added")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f10-viewer-landscape")
        app.swipeLeft()
        shot("f10b-viewer-landscape-swiped")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["viewer-close"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f11-grid-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons.firstMatch.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f12-collections-landscape")
        XCUIDevice.shared.orientation = .portrait

        // History's guide.
        app.tabBars.buttons["History"].tap()
        app.buttons["history-info"].tap()
        shot("f13-history-guide")
        app.swipeUp()
        shot("f13b-history-guide-rail")
        app.buttons["history-guide-done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f14-history-landscape")
        XCUIDevice.shared.orientation = .portrait

        // Decks: a folder and the view options.
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        app.buttons["decks-add"].tap()
        shot("f15-decks-add-menu")
        app.buttons["decks-menu-folder"].tap()
        app.alerts.textFields.firstMatch.typeText("Commander")
        app.alerts.buttons["Create"].tap()
        shot("f16-decks-with-folder")
        app.buttons["decks-view-menu"].tap()
        shot("f17-decks-view-menu")
        app.buttons["List"].firstMatch.tap()
        shot("f18-decks-list")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f19-decks-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-link"].tap()
        shot("f20-import-from-link")
        app.buttons["Cancel"].firstMatch.tap()

        // Search: the Sets page.
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.segmentedControls["search-mode"].waitForExistence(timeout: 10))
        shot("f21-search-landing")
        app.segmentedControls["search-mode"].buttons["Sets"].tap()
        _ = app.buttons["sets-kind"].waitForExistence(timeout: 15)
        shot("f22-sets")
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("f23-sets-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.segmentedControls["search-mode"].buttons["Cards"].tap()

        // Scan.
        app.tabBars.buttons["Scan"].tap()
        shot("f24-scan")
    }
}
