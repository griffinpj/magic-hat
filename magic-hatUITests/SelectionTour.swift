//
//  SelectionTour.swift
//  magic-hatUITests
//
//  Screenshots for vetting: selection in a collection, search results and
//  a deck; the Decks guide, Select Decks, and a folder in List view with
//  its search field. Written to `TEST_RUNNER_UITEST_SHOT_DIR`; skipped
//  when that isn't set. Search results need the network.
//

import XCTest

final class SelectionTour: XCTestCase {
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

    @MainActor
    func testSelectionTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()

        // Collection: long press, then the Add menu.
        app.staticTexts["Test Collection"].tap()
        let first = app.staticTexts["Card 0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.8)
        app.staticTexts["Card 10"].firstMatch.tap()
        app.staticTexts["Card 100"].firstMatch.tap()
        shot("x01-collection-selecting")
        app.buttons["selection-add"].tap()
        shot("x02-add-menu")
        app.tap()
        app.buttons["selection-done"].tap()
        app.navigationBars["Test Collection"].buttons.firstMatch.tap()

        // Search results: sort button and selection.
        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        field.typeText("dragon\n")
        let result = app.scrollViews.firstMatch
        _ = result.waitForExistence(timeout: 15)
        sleep(4)
        shot("x03-search-results")
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.4)).press(forDuration: 0.8)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
        shot("x04-search-selecting")
        if app.buttons["selection-done"].exists { app.buttons["selection-done"].tap() }
        app.buttons["search-clear"].firstMatch.tap()
        shot("x05-search-landing")

        // Decks: a folder with a deck, in List view.
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-folder"].tap()
        app.alerts.textFields.firstMatch.typeText("Commander")
        app.alerts.buttons["Create"].tap()
        app.buttons["deck-folder-Commander"].tap()
        XCTAssertTrue(app.navigationBars["Commander"].waitForExistence(timeout: 5))
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-new"].tap()
        let nameField = app.textFields["newdeck-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Foldered Deck")
        app.buttons["newdeck-create"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Foldered Deck"].waitForExistence(timeout: 10))
        // A deck's rows, selecting.
        app.navigationBars["Foldered Deck"].buttons.firstMatch.tap()
        app.buttons["decks-view-menu"].tap()
        app.buttons["List"].firstMatch.tap()
        shot("x06-folder-list-view")
        app.buttons["decks-view-menu"].tap()
        app.buttons["decks-select"].tap()
        app.buttons["deck-tile-Foldered Deck"].firstMatch.tap()
        shot("x07-select-decks")
        app.buttons["decks-selection-done"].tap()
        app.navigationBars["Commander"].buttons.firstMatch.tap()
        shot("x08-decks-root-list")
        app.buttons["decks-info"].tap()
        shot("x09-decks-guide")
        app.buttons["decks-guide-done"].tap()
    }
}
