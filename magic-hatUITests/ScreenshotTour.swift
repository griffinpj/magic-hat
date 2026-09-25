//
//  ScreenshotTour.swift
//  magic-hatUITests
//
//  Not a test of behaviour: a tour that drives the seeded app through the
//  screens and writes a PNG of each, for vetting a change by eye. Runs
//  only when `TEST_RUNNER_UITEST_SHOT_DIR` names a directory to write
//  into; otherwise it is skipped, so the suite stays green and fast.
//
//    TEST_RUNNER_UITEST_SHOT_DIR=/path/to/shots xcodebuild test … \
//      -only-testing:magic-hatUITests/ScreenshotTour
//

import XCTest

final class ScreenshotTour: XCTestCase {
    private var dir: URL?

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SHOT_DIR to take screenshots.")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        usleep(600_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()

        // Collections: All Collection row, rows without chevrons.
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.buttons["collection-all"].waitForExistence(timeout: 10))
        shot("01-collections")

        // Search filters: focusing the type line scrolls it up so its
        // suggestions sit above the keyboard.
        app.tabBars.buttons["Search"].tap()
        let typeField = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Add a type'")).firstMatch
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        // Rows below the fold aren't in the tree until scrolled to.
        for _ in 0..<6 where !typeField.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(typeField.waitForExistence(timeout: 5))
        typeField.tap()
        let intro = app.buttons["Continue"]
        if intro.waitForExistence(timeout: 2) { intro.tap() }
        typeField.typeText("dra")
        shot("01b-search-type-suggestions")
        let done = app.keyboards.buttons["Done"]
        if done.exists { done.tap() } else { app.swipeDown() }

        // A commander deck from the clipboard: Card 3 (red) commands, Card 7 is blue.
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        var list = "// COMMANDER\n1 Card 3\n\n"
        for i in stride(from: 6, to: 90, by: 6) { list += "1 Card \(i)\n" }   // creatures (i % 3 == 0), instants otherwise
        for i in stride(from: 7, to: 60, by: 6) { list += "1 Card \(i)\n" }
        UIPasteboard.general.string = list
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let name = app.textFields["import-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Tour Deck")
        app.buttons["import-run"].tap()
        XCTAssertTrue(app.navigationBars["Tour Deck"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["deck-issues"].waitForExistence(timeout: 5))
        shot("02-deck-cards-top")
        app.swipeUp()
        shot("03-deck-cards-scrolled")

        // The row right after the commander → viewer on that card.
        app.swipeDown()
        app.swipeDown()
        let second = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row-'")).element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        let secondName = second.identifier.replacingOccurrences(of: "deck-row-", with: "")
        second.tap()
        XCTAssertTrue(app.navigationBars[secondName].waitForExistence(timeout: 5), "viewer on \(secondName)")
        shot("04-viewer-second-row")
        app.buttons["viewer-synergies"].tap()
        XCTAssertTrue(app.navigationBars["Synergies"].waitForExistence(timeout: 5))
        shot("04b-synergies-offline")
        app.navigationBars["Synergies"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        app.buttons["viewer-close"].tap()

        // Swipe between pages.
        XCTAssertTrue(app.buttons["deck-issues"].waitForExistence(timeout: 5))
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Average mana value"].waitForExistence(timeout: 5))
        shot("05-deck-stats")
        app.swipeUp()
        shot("05b-deck-stats-scrolled")
        app.swipeUp()
        shot("05c-deck-stats-mana")
        // The analysis and the recommendations, pushed from Stats. The
        // list is lazy and the Check section above can be long: back to
        // the top, then down until the row is in the tree.
        let analysisRow = app.buttons["deck-analysis"].firstMatch
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        for _ in 0..<8 where !analysisRow.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(analysisRow.waitForExistence(timeout: 10))
        analysisRow.tap()
        XCTAssertTrue(app.navigationBars["Analysis"].waitForExistence(timeout: 5))
        shot("05d-deck-analysis")
        app.swipeUp()
        shot("05e-deck-analysis-scrolled")
        // Back to the deck; the recommendations open the add sheet on their
        // own scope, and the swaps push from the Stats row.
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 10), "back on the deck")
        let recRow = app.buttons["deck-recommendations"].firstMatch
        for _ in 0..<8 where !(recRow.exists && recRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(recRow.waitForExistence(timeout: 5))
        recRow.tap()
        XCTAssertTrue(app.navigationBars["Add Cards"].waitForExistence(timeout: 5))
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-add-'")).firstMatch.waitForExistence(timeout: 20)
        shot("05f-recommended-in-add-sheet")
        app.buttons["deck-add-done"].tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))
        let swapsRow = app.buttons["deck-swaps"].firstMatch
        for _ in 0..<8 where !(swapsRow.exists && swapsRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(swapsRow.waitForExistence(timeout: 5))
        swapsRow.tap()
        XCTAssertTrue(app.navigationBars["Swaps"].waitForExistence(timeout: 5))
        usleep(800_000)
        shot("05g-swaps")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 10), "back on the deck")
        app.segmentedControls["deck-tabs"].buttons["Cards"].tap()
        XCTAssertTrue(app.buttons["deck-issues"].waitForExistence(timeout: 5))
        shot("05h-cards-with-swaps-row")
        app.segmentedControls["deck-tabs"].buttons["Details"].tap()
        let export = app.buttons["deck-export"].firstMatch
        for _ in 0..<6 where !export.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        shot("06-deck-details")

        // Export sheet, from the menu.
        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-export"].tap()
        XCTAssertTrue(app.staticTexts["export-preview"].waitForExistence(timeout: 5))
        shot("07-export")
        app.switches["export-missing"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.segmentedControls["export-format"].buttons["Arena"].tap()
        shot("08-export-arena-missing")
        app.buttons["export-cancel"].tap()

        // Add sheet with the issues line and an off-identity tag.
        app.swipeRight()
        app.swipeRight()
        XCTAssertTrue(app.buttons["deck-add-cards"].waitForExistence(timeout: 5))
        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["deck-add-issues"].waitForExistence(timeout: 5))
        shot("09-add-sheet")
        // A button-style Toggle is a Switch to accessibility, labelled with
        // its pips ("Within identity, Red"); it appears once the sheet has
        // read the deck's snapshot.
        let identity = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Within identity'")).firstMatch
        XCTAssertTrue(identity.waitForExistence(timeout: 10))
        identity.tap()
        field.tap()
        // A fresh simulator shows the keyboard's swipe-typing tip first.
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        field.typeText("Card 1")
        XCTAssertTrue(app.buttons["deck-search-row-Card 1"].waitForExistence(timeout: 5))
        shot("10-add-sheet-off-identity")
        app.buttons["deck-add-done"].tap()
    }
}
