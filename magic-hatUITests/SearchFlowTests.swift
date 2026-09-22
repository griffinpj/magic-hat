//
//  SearchFlowTests.swift
//  magic-hatUITests
//
//  The parts of Search that need no network: the filter sheet commits and
//  resets, and a search can be saved and appears on the idle screen.
//

import XCTest

final class SearchFlowTests: XCTestCase {

    private func launchOnSearch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        return app
    }

    /// Form rows are created lazily; swipe until the element exists.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.exists, "could not scroll to \(element)")
    }

    @MainActor
    func testFilterSheetCommitsAndResets() {
        let app = launchOnSearch()
        let filters = app.buttons["search-filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertEqual(filters.value as? String, "none")
        filters.tap()

        let done = app.buttons["filters-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "filter sheet")
        XCTAssertFalse(app.buttons["filters-reset"].isEnabled, "nothing to reset yet")

        let rare = app.descendants(matching: .any)["filter-rarity-rare"]
        reveal(rare, in: app)
        rare.tap()
        let foil = app.descendants(matching: .any)["filter-finish-foil"]
        reveal(foil, in: app)
        foil.tap()
        XCTAssertTrue(app.buttons["filters-reset"].isEnabled)
        done.tap()

        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertEqual(filters.value as? String, "2 active", "two filter groups set")

        filters.tap()
        XCTAssertTrue(app.buttons["filters-reset"].waitForExistence(timeout: 5))
        app.buttons["filters-reset"].tap()
        app.buttons["filters-done"].tap()
        XCTAssertEqual(filters.value as? String, "none")
    }

    @MainActor
    func testSaveSearchAppearsInMenuAndList() {
        let app = launchOnSearch()
        // Set a filter so there is something to save without typing. (Done
        // also runs the search, so the idle screen is gone from here on.)
        app.buttons["search-filters"].tap()
        XCTAssertTrue(app.buttons["filters-done"].waitForExistence(timeout: 5))
        let mythic = app.descendants(matching: .any)["filter-rarity-mythic"]
        reveal(mythic, in: app)
        mythic.tap()
        app.buttons["filters-done"].tap()

        app.buttons["search-saved"].tap()
        let save = app.buttons["Save Search…"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "saved-searches menu")
        save.tap()

        // The alert proposes a name from the query ("Mythic"); accept it.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "name alert")
        app.buttons["Save"].tap()

        app.buttons["search-saved"].tap()
        XCTAssertTrue(app.buttons["Mythic"].waitForExistence(timeout: 5), "saved search in the bookmark menu")
        app.buttons["Edit Saved Searches…"].tap()
        XCTAssertTrue(app.navigationBars["Saved Searches"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mythic"].firstMatch.exists, "saved search row")
    }
}
