//
//  PlaytestFlowTests.swift
//  magic-hatUITests
//
//  The playtest table on a seeded deck: seven in hand, a card played with
//  a tap, tapped with another, a turn untapping and drawing, a card sent
//  to the graveyard from its menu and found in the graveyard sheet, and
//  New Game resetting it all. Screenshots go to `UITEST_SHOT_DIR` when set.
//

import XCTest

final class PlaytestFlowTests: XCTestCase {
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        usleep(700_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testGoldfishAGame() {
        continueAfterFailure = false
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
        name.typeText("Goldfish")
        app.descendants(matching: .any)["newdeck-format"].tap()
        app.buttons["Casual"].tap()
        app.buttons["newdeck-create"].tap()
        XCTAssertTrue(app.navigationBars["Goldfish"].waitForExistence(timeout: 10))

        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Card 12")
        let cards = ["Card 12"] + (0..<10).map { "Card 12\($0)" }
        for card in cards {
            let add = app.buttons["deck-search-add-\(card)"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), card)
            add.tap()
        }
        app.buttons["deck-add-done"].tap()

        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-playtest"].tap()
        XCTAssertTrue(app.buttons["playtest-done"].waitForExistence(timeout: 5))
        let turn = app.descendants(matching: .any)["playtest-stat-Turn"]
        let library = app.descendants(matching: .any)["playtest-stat-Library"]
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        // Eleven cards: seven in hand, four left.
        XCTAssertEqual(library.label, "Library, 4")
        let hand = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'playtest-hand-'"))
        XCTAssertEqual(hand.count, 7, "seven drawn")
        shot("p01-opening-hand")

        // Play the first card in hand, then tap it.
        let first = hand.element(boundBy: 0)
        let played = first.identifier.replacingOccurrences(of: "playtest-hand-", with: "")
        first.tap()
        let onTable = app.descendants(matching: .any)["playtest-battlefield-\(played)"]
        XCTAssertTrue(onTable.waitForExistence(timeout: 5), "played onto the battlefield")
        XCTAssertEqual(hand.count, 6)
        onTable.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'tapped'")).firstMatch.waitForExistence(timeout: 3), "tapped")
        shot("p02-played-and-tapped")

        // Next turn untaps and draws.
        app.buttons["playtest-next-turn"].tap()
        XCTAssertTrue(turn.waitForExistence(timeout: 3))
        XCTAssertEqual(turn.label, "Turn, 2")
        XCTAssertEqual(hand.count, 7, "drew for the turn")
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'tapped'")).firstMatch.exists, "untapped")
        XCTAssertFalse(app.buttons["playtest-mulligan"].isEnabled, "no mulligan after turn one")

        // A card to the graveyard from its menu, then the graveyard sheet.
        let second = hand.element(boundBy: 0)
        let binned = second.identifier.replacingOccurrences(of: "playtest-hand-", with: "")
        second.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["To Graveyard"].waitForExistence(timeout: 5))
        shot("p03-card-menu")
        app.buttons["To Graveyard"].tap()
        XCTAssertEqual(hand.count, 6)
        let graveyard = app.descendants(matching: .any)["playtest-graveyard"]
        XCTAssertTrue(graveyard.isEnabled)
        graveyard.tap()
        XCTAssertTrue(app.staticTexts[binned].waitForExistence(timeout: 5), "listed in the graveyard")
        shot("p04-graveyard")
        app.buttons["Done"].firstMatch.tap()

        // New game resets everything.
        app.buttons["playtest-menu"].tap()
        app.buttons["New Game"].tap()
        XCTAssertTrue(app.buttons["New Game"].waitForExistence(timeout: 3))
        app.buttons["New Game"].tap()
        XCTAssertEqual(turn.label, "Turn, 1", "turn 1 again")
        XCTAssertEqual(hand.count, 7)
        XCTAssertFalse(graveyard.isEnabled, "graveyard empty")
        app.buttons["playtest-done"].tap()
        XCTAssertTrue(app.navigationBars["Goldfish"].waitForExistence(timeout: 5))

        // Details lists the tokens the deck makes: Card 120 makes a Soldier
        // and a Treasure in the seed.
        app.buttons["Details"].firstMatch.tap()
        let soldier = app.descendants(matching: .any)["deck-token-Soldier"]
        for _ in 0..<6 where !soldier.exists { app.swipeUp() }
        XCTAssertTrue(soldier.exists, "the Soldier token is listed")
        XCTAssertTrue(soldier.label.contains("Made by Card 120"), soldier.label)
        XCTAssertTrue(app.descendants(matching: .any)["deck-token-Treasure"].exists)
        shot("p05-tokens")
    }
}
