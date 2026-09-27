//
//  FeatureFlowTests.swift
//  magic-hatUITests
//
//  The flows added together: History's guide, Settings and About, a list
//  made and filled by moving a selection into it, the viewer's quick add,
//  deck folders, the Search tab's Sets page, and the Scan tab without a
//  camera. Seeded store, no network needed.
//

import XCTest

final class FeatureFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        return app
    }

    @MainActor
    func testHistoryGuideAndSettings() {
        let app = launch()
        app.tabBars.buttons["History"].tap()
        let info = app.buttons["history-info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10))
        info.tap()
        XCTAssertTrue(app.navigationBars["About History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["A new change starts a branch"].exists)
        app.buttons["history-guide-done"].tap()

        app.tabBars.buttons["Collection"].tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings-check-updates"].exists || app.staticTexts["Card Catalog"].exists)
        let about = app.buttons["settings-about"]
        for _ in 0..<4 where !about.exists { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.staticTexts["about-version"].waitForExistence(timeout: 5))
        app.buttons["about-privacy"].tap()
        XCTAssertTrue(app.navigationBars["Privacy Policy"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testListFromASelectionAndQuickAdd() {
        let app = launch()
        // A new list, from the Collections menu; it opens empty.
        app.buttons["collections-menu"].tap()
        app.buttons["new-list-menu"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Wants")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Wants"].waitForExistence(timeout: 5))
        app.navigationBars["Wants"].buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Lists"].waitForExistence(timeout: 5), "the list sits under its own heading")

        // Select two cards in the collection and move them onto the list.
        app.staticTexts["Test Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 0"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["collection-more"].tap()
        app.buttons["collection-select"].tap()
        app.staticTexts["Card 0"].firstMatch.tap()
        app.staticTexts["Card 1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["selection-count"].label.hasPrefix("2 Selected"), app.staticTexts["selection-count"].label)
        app.buttons["selection-move"].tap()
        app.buttons["Wants"].tap()
        XCTAssertTrue(app.buttons["collection-more"].waitForExistence(timeout: 10), "out of selection after the move")

        // The viewer's Add, held: a menu of places, one tap adds a copy.
        let tile = app.staticTexts["Card 10"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        let add = app.buttons["viewer-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.press(forDuration: 1.0)
        let wants = app.buttons["Wants"]
        XCTAssertTrue(wants.waitForExistence(timeout: 5))
        wants.tap()
        XCTAssertTrue(app.descendants(matching: .any)["viewer-quick-added"].waitForExistence(timeout: 5))
        app.buttons["viewer-close"].tap()

        // The list holds the three cards.
        app.navigationBars.buttons.firstMatch.tap()
        let list = app.buttons["collection-Wants"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let unique = NSPredicate(format: "label ENDSWITH '· 3 unique'")
        XCTAssertTrue(app.staticTexts.matching(unique).firstMatch.waitForExistence(timeout: 10), list.label)
    }

    @MainActor
    func testDeckFolders() {
        let app = launch()
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        // A deck to file.
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-new"].tap()
        let deckName = app.textFields["newdeck-name"]
        XCTAssertTrue(deckName.waitForExistence(timeout: 5))
        deckName.tap()
        deckName.typeText("Filed Deck")
        app.buttons["newdeck-create"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Filed Deck"].waitForExistence(timeout: 10))
        app.navigationBars["Filed Deck"].buttons.firstMatch.tap()

        // A folder, then Move the deck into it from its context menu.
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-folder"].tap()
        let folderName = app.alerts.textFields.firstMatch
        XCTAssertTrue(folderName.waitForExistence(timeout: 5))
        folderName.typeText("Commander")
        app.alerts.buttons["Create"].tap()
        let folder = app.buttons["deck-folder-Commander"]
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        let tile = app.buttons["deck-tile-Filed Deck"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.press(forDuration: 1.2)
        app.buttons["Move…"].tap()
        app.buttons["move-to-Commander"].tap()
        XCTAssertTrue(tile.waitForNonExistence(timeout: 5), "filed away")
        folder.tap()
        XCTAssertTrue(app.navigationBars["Commander"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["deck-tile-Filed Deck"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testSetsPageAndScanWithoutCamera() {
        let app = launch()
        app.tabBars.buttons["Search"].tap()
        let mode = app.segmentedControls["search-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Sets"].tap()
        // Online: the list; offline: the retry. Either way, not the form.
        let loaded = app.buttons["sets-kind"].waitForExistence(timeout: 15) || app.buttons["Try Again"].waitForExistence(timeout: 5)
        XCTAssertTrue(loaded)
        mode.buttons["Cards"].tap()
        XCTAssertTrue(app.buttons["search-run"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Scan"].tap()
        // The simulator has no camera: the page says so and offers a photo.
        XCTAssertTrue(app.staticTexts["No Camera"].waitForExistence(timeout: 10) || app.staticTexts["scan-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["scan-photo"].exists || app.buttons["Scan a Photo"].exists)
    }
}
