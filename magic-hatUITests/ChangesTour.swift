//
//  ChangesTour.swift
//  magic-hatUITests
//
//  Screenshots for vetting: the sort menu's two directions, a long
//  History through its window (Show Earlier, a branch's Show All, the
//  branch that comes into view with its fork), and Try Cards — the empty
//  state, results, a pick's verdict and its menu of other cuts. Written
//  to `TEST_RUNNER_UITEST_SHOT_DIR`; skipped when that isn't set. Try
//  Cards searches Scryfall, so it needs the network.
//

import XCTest

final class ChangesTour: XCTestCase {
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
    func testSortAndLongHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launchEnvironment["UITEST_HISTORY_COUNT"] = "120"
        app.launch()

        app.staticTexts["Test Collection"].tap()
        XCTAssertTrue(app.buttons["sort-button"].waitForExistence(timeout: 10))
        app.buttons["sort-button"].tap()
        app.buttons["Price"].firstMatch.tap()
        app.buttons["sort-button"].tap()
        shot("c01-sort-menu")
        app.buttons["sort-ascending"].tap()
        shot("c02-price-ascending")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons["history-undo"].waitForExistence(timeout: 10))
        shot("c03-history-top")
        let earlier = app.buttons["history-show-earlier"]
        for _ in 0..<14 where !earlier.isHittable { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(earlier.exists, "a long history ends in Show Earlier")
        shot("c04-history-show-earlier")
        // Two more pages: everything is drawn, and the branch that split
        // from the tenth action comes into view with it.
        for _ in 0..<2 {
            for _ in 0..<14 where !earlier.isHittable { app.swipeUp(velocity: .fast) }
            earlier.tap()
        }
        for _ in 0..<30 { app.swipeUp(velocity: .fast) }
        XCTAssertFalse(earlier.exists, "nothing earlier is left")
        XCTAssertTrue(app.staticTexts["Splits from Added Card 4 in Timeline"].exists, "the old branch shows once its fork does")
        shot("c06-history-all-with-old-branch")
    }

    @MainActor
    func testTryCards() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-new"].tap()
        let name = app.textFields["newdeck-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Tour Deck")
        app.descendants(matching: .any)["newdeck-format"].tap()
        app.buttons["Casual"].tap()
        app.buttons["newdeck-create"].tap()
        XCTAssertTrue(app.navigationBars["Tour Deck"].waitForExistence(timeout: 10))

        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Card 12")
        for card in ["Card 12", "Card 120", "Card 121", "Card 122", "Card 123", "Card 124"] {
            let add = app.buttons["deck-search-add-\(card)"]
            if add.waitForExistence(timeout: 10) { add.tap() }
        }
        app.buttons["deck-add-done"].tap()

        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-propose"].tap()
        XCTAssertTrue(app.buttons["propose-done"].waitForExistence(timeout: 5))
        shot("t01-try-empty")
        app.buttons["propose-start"].tap()
        let search = app.searchFields.firstMatch
        search.typeText("sol ring")
        let pick = app.buttons["propose-pick-Sol Ring"]
        XCTAssertTrue(pick.waitForExistence(timeout: 20), "Scryfall's results")
        shot("t02-try-results")
        pick.tap()
        XCTAssertTrue(app.descendants(matching: .any)["propose-row-Sol Ring"].waitForExistence(timeout: 10))
        sleep(2)
        shot("t03-try-verdict")
        search.tap()
        search.typeText("command tower")
        let tower = app.buttons["propose-pick-Command Tower"]
        if tower.waitForExistence(timeout: 20) { tower.tap() }
        sleep(2)
        shot("t04-try-two-picks")
        for id in ["propose-change-Sol Ring", "propose-anyway-Sol Ring", "propose-change-Command Tower", "propose-anyway-Command Tower"] {
            let menu = app.buttons[id]
            if menu.exists { menu.tap(); shot("t05-try-cut-menu"); app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Card 12'")).firstMatch.tap(); break }
        }
        shot("t06-try-chosen-cut")
    }
}
