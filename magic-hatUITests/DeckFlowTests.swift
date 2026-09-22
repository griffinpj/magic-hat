//
//  DeckFlowTests.swift
//  magic-hatUITests
//
//  The deck life cycle on the seeded store, no network: create a deck, add
//  a card from the collection search, build it (the card moves out of the
//  collection), disassemble it (the card comes back); and import a list
//  from the clipboard.
//

import XCTest

final class DeckFlowTests: XCTestCase {

    private func launchOnDecks() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        return app
    }

    /// Casual format: the seed's cards carry no legality data, so a format
    /// with a legality check would (correctly) hide them all.
    private func createCasualDeck(_ app: XCUIApplication, named name: String) {
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-new"].tap()
        let field = app.textFields["newdeck-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(name)
        let format = app.descendants(matching: .any)["newdeck-format"]
        XCTAssertTrue(format.waitForExistence(timeout: 5))
        format.tap()
        XCTAssertTrue(app.buttons["Casual"].waitForExistence(timeout: 5))
        app.buttons["Casual"].tap()
        app.buttons["newdeck-create"].tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "the new deck opens")
    }

    @MainActor
    func testCreateAddBuildAndDisassemble() {
        let app = launchOnDecks()
        createCasualDeck(app, named: "UI Deck")

        // Add from the collection search.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Card 120")
        let add = app.buttons["deck-search-add-Card 120"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "collection search result")
        add.tap()
        clearSearch(app, field)

        let row = app.descendants(matching: .any)["deck-row-Card 120"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the card is on the list")
        XCTAssertTrue((row.value as? String)?.contains("In collection") == true, "available, not yet built: \(row.value ?? "")")

        // Build: the seed collection is the only source.
        app.buttons["deck-menu"].tap()
        app.buttons["Build Deck…"].tap()
        let cont = app.buttons["build-continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5))
        cont.tap()
        let confirm = app.buttons["build-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "plan reviewed")
        confirm.tap()
        let done = app.buttons["build-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        let built = app.descendants(matching: .any)["deck-row-Card 120"].firstMatch
        XCTAssertTrue(built.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(built, containing: "In deck"), "built")

        // Disassemble: back to the collection.
        app.buttons["deck-menu"].tap()
        app.buttons["Disassemble Deck…"].tap()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(waitForValue(app.descendants(matching: .any)["deck-row-Card 120"].firstMatch, containing: "In collection"), "returned")

        // Lock: the field now filters the deck, and the stepper is gone.
        app.buttons["deck-menu"].tap()
        app.buttons["Lock Deck"].tap()
        XCTAssertTrue(app.buttons["Fewer Card 120"].waitForNonExistence(timeout: 5), "no editing while locked")
    }

    @MainActor
    func testImportFromClipboard() {
        let app = launchOnDecks()
        UIPasteboard.general.string = "// COMMANDER\n1 Card 3\n\n2 Card 5\n1 Card 7\n1 Not A Real Card\n"
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "system paste button, no permission prompt")
        paste.tap()
        let name = app.textFields["import-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Clip Deck")
        XCTAssertTrue(app.staticTexts["Commander"].waitForExistence(timeout: 5), "the summary read the pasted list")
        app.buttons["import-run"].tap()
        // One line can't resolve; the sheet says so, then opens the deck.
        let ok = app.buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 15), "not-found alert")
        ok.tap()
        XCTAssertTrue(app.navigationBars["Clip Deck"].waitForExistence(timeout: 10))
        let five = app.descendants(matching: .any)["deck-row-Card 5"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        XCTAssertTrue((five.value as? String)?.hasPrefix("2,") == true, "two copies: \(five.value ?? "")")
        XCTAssertTrue(app.descendants(matching: .any)["deck-row-Card 3"].firstMatch.exists, "the commander")
    }

    /// Empties the field so the deck list shows again (the search session
    /// may stay active; that's fine).
    private func clearSearch(_ app: XCUIApplication, _ field: XCUIElement) {
        let clear = field.buttons["Clear text"]
        if clear.exists { clear.tap() } else {
            let count = (field.value as? String)?.count ?? 0
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count))
        }
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String)?.contains(text) == true { return true }
            usleep(200_000)
        }
        return false
    }
}
