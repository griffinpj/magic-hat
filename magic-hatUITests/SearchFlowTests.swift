//
//  SearchFlowTests.swift
//  magic-hatUITests
//
//  The parts of Search that need no network: the landing screen's inline
//  filters apply and reset, the keyboard can be dismissed, and a search can
//  be saved and shows up on the landing screen.
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
        while !element.exists && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(element.exists, "could not scroll to \(element)")
    }

    @MainActor
    func testLandingFiltersApplyAndReset() {
        let app = launchOnSearch()
        let run = app.buttons["search-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 5), "landing shows the Search button")
        XCTAssertFalse(run.isEnabled, "nothing to search yet")

        // Formats are inline chips at the top of the form.
        let modern = app.descendants(matching: .any)["filter-format-modern"]
        XCTAssertTrue(modern.waitForExistence(timeout: 5))
        modern.tap()
        XCTAssertTrue(run.isEnabled, "a filter is enough to search")

        let rare = app.descendants(matching: .any)["filter-rarity-rare"]
        reveal(rare, in: app)
        rare.tap()

        let reset = app.buttons["filters-reset"]
        reveal(reset, in: app)
        XCTAssertTrue(reset.isEnabled)
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        XCTAssertFalse(run.isEnabled)
    }

    /// Number pads have no return key; the keyboard bar's Done must exist
    /// and put the keyboard away.
    @MainActor
    func testKeyboardDoneDismisses() {
        let app = launchOnSearch()
        let minimum = app.textFields["Any"].firstMatch
        reveal(minimum, in: app)
        minimum.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard up")
        minimum.typeText("5")
        let done = app.buttons["keyboard-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Done on the keyboard bar")
        done.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "keyboard dismissed")
    }

    @MainActor
    func testSaveSearchAppearsOnLanding() {
        let app = launchOnSearch()
        let pauper = app.descendants(matching: .any)["filter-format-pauper"]
        XCTAssertTrue(pauper.waitForExistence(timeout: 5))
        pauper.tap()

        app.buttons["search-saved"].tap()
        let save = app.buttons["Save Search…"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "saved-searches menu")
        save.tap()

        // The alert proposes a name from the query ("Pauper"); accept it.
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5), "name alert")
        app.buttons["Save"].tap()

        // Nothing ran, so the landing form is still up — with the new row.
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Saved Searches"].waitForExistence(timeout: 5), "saved section on the landing")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pauper'")).firstMatch.exists, "saved row")

        app.buttons["search-saved"].tap()
        XCTAssertTrue(app.buttons["Pauper"].waitForExistence(timeout: 5), "saved search in the bookmark menu")
        app.buttons["Edit Saved Searches…"].tap()
        XCTAssertTrue(app.navigationBars["Saved Searches"].waitForExistence(timeout: 5))
    }
}
