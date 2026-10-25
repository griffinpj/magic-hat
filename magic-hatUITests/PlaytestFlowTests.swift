//
//  PlaytestFlowTests.swift
//  magic-hatUITests
//
//  The playtest table on a seeded deck (the seeded run shuffles on a
//  fixed seed): the opening hand and a London mulligan with its card to
//  the bottom, a land fetched by a library search and dragged onto the
//  battlefield (and first let go short of it, staying in hand), an
//  instant cast from the table's inspector — into the graveyard, never
//  onto the battlefield — a creature dragged out and summoning sick, the
//  inspector on the battlefield, End Turn, an attack that taps it, Undo,
//  the graveyard and flashback, and New Game back to the opening hand.
//  Screenshots go to `UITEST_SHOT_DIR` when set.
//

import XCTest

final class PlaytestFlowTests: XCTestCase {
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        usleep(700_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// A screenshot taken while a gesture is still under way (the press
    /// blocks the test): the held card's preview, the lit battlefield.
    private func shot(_ name: String, after delay: TimeInterval) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
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

        // Eleven seeded cards — creatures and instants — and a Forest (Card 899).
        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Card 12")
        for card in ["Card 12"] + (0..<10).map({ "Card 12\($0)" }) {
            let add = app.buttons["deck-search-add-\(card)"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), card)
            add.tap()
        }
        field.buttons["Clear text"].firstMatch.tap()
        field.typeText("Card 899")
        let forest = app.buttons["deck-search-add-Card 899"]
        XCTAssertTrue(forest.waitForExistence(timeout: 10))
        forest.tap()
        app.buttons["deck-add-done"].tap()

        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-playtest"].tap()
        XCTAssertTrue(app.buttons["playtest-done"].waitForExistence(timeout: 5))

        // The opening hand: nothing is played until it is kept.
        let hand = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'playtest-hand-'"))
        XCTAssertTrue(app.descendants(matching: .any)["playtest-opening"].waitForExistence(timeout: 5))
        XCTAssertEqual(hand.count, 7, "seven drawn")
        let keep = app.buttons["playtest-keep"]
        XCTAssertEqual(keep.label, "Keep 7")
        shot("p01-opening-hand")

        // A London mulligan: seven again, one to the bottom on keeping.
        app.buttons["playtest-mulligan"].tap()
        XCTAssertEqual(hand.count, 7)
        XCTAssertEqual(keep.label, "Keep 6")
        keep.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playtest-bottom-banner"].waitForExistence(timeout: 3))
        shot("p02-bottom-one")
        hand.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Turn 1"].waitForExistence(timeout: 3))
        XCTAssertEqual(hand.count, 6, "kept six; on the play there is no first draw")
        let library = app.descendants(matching: .any)["playtest-library"]
        XCTAssertEqual(library.label, "Library, 6")

        // The Forest, by searching the library if it isn't in hand, dragged
        // onto the battlefield as the turn's land.
        let battlefield = app.descendants(matching: .any)["playtest-battlefield"]
        let landInHand = app.descendants(matching: .any)["playtest-hand-Card 899"]
        if !landInHand.exists {
            library.tap()
            app.buttons["Search Library…"].tap()
            let row = app.descendants(matching: .any)["playtest-search-Card 899"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            shot("p03-search")
            row.tap()
            app.buttons["To Hand"].tap()
            XCTAssertTrue(landInHand.waitForExistence(timeout: 5))
        }
        // Holding a card shows it large, and plays nothing.
        shot("p03a-held", after: 1.2)
        landInHand.press(forDuration: 2.0)
        XCTAssertTrue(landInHand.exists, "holding plays nothing")
        // Let go short of the battlefield: it goes back into the hand.
        landInHand.press(forDuration: 0.05, thenDragTo: app.descendants(matching: .any)["playtest-mana"])
        XCTAssertTrue(landInHand.exists, "not played below the line")
        landInHand.press(forDuration: 0.05, thenDragTo: battlefield)
        XCTAssertTrue(app.descendants(matching: .any)["playtest-battlefield-Card 899"].waitForExistence(timeout: 5), "dragged onto the battlefield")
        XCTAssertTrue(app.descendants(matching: .any)["playtest-mana"].label.contains("1 of 1"))

        // An instant, opened with a tap: the table's own inspector, which
        // casts it — into the graveyard; it never touches the table.
        let instant = hand.matching(NSPredicate(format: "value == 'Instant'")).firstMatch
        XCTAssertTrue(instant.exists, "an instant in hand")
        let instantName = instant.identifier.replacingOccurrences(of: "playtest-hand-", with: "")
        instant.tap()
        let primary = app.buttons["playtest-inspector-primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 5), "the inspector opens")
        XCTAssertTrue(primary.label.contains("Cast \(instantName)"), primary.label)
        XCTAssertFalse(app.buttons["playtest-option-Put onto the Battlefield"].exists, "an instant is never put onto the battlefield")
        shot("p04-inspector")
        primary.tap()
        XCTAssertTrue(app.descendants(matching: .any)["playtest-toast"].waitForExistence(timeout: 3), "the toast says where it went")
        let graveyard = app.descendants(matching: .any)["playtest-graveyard"]
        XCTAssertTrue(graveyard.waitForExistence(timeout: 3))
        XCTAssertTrue(waitFor(graveyard, label: "Graveyard, 1 cards"), graveyard.label)
        XCTAssertFalse(app.descendants(matching: .any)["playtest-battlefield-\(instantName)"].exists, "an instant is not a permanent")
        shot("p05-instant-resolved")

        // A creature, dragged up: the table asks about the mana it lacks,
        // then it stays, summoning sick.
        let creature = hand.matching(NSPredicate(format: "value == 'Creature'")).firstMatch
        XCTAssertTrue(creature.exists, "a creature in hand")
        let creatureName = creature.identifier.replacingOccurrences(of: "playtest-hand-", with: "")
        shot("p05a-carried", after: 1.4)
        creature.press(forDuration: 0.05, thenDragTo: battlefield, withVelocity: .default, thenHoldForDuration: 2.0)
        castAnywayIfAsked(app)
        let onTable = app.descendants(matching: .any)["playtest-battlefield-\(creatureName)"]
        XCTAssertTrue(onTable.waitForExistence(timeout: 5), "cast onto the battlefield")
        XCTAssertTrue(onTable.label.contains("summoning sick"), onTable.label)
        shot("p06-creature-cast")

        // Holding it on the battlefield opens its sheet there.
        onTable.press(forDuration: 0.8)
        XCTAssertTrue(app.descendants(matching: .any)["playtest-inspector-where"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["playtest-inspector-where"].label.contains("summoning sick"))
        XCTAssertTrue(app.buttons["playtest-inspector-primary"].label.contains("Tap"))
        shot("p07-battlefield-inspector")
        // A sheet: dragging it down puts it away.
        let sheet = app.descendants(matching: .any)["playtest-inspector"]
        sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertTrue(waitForGone(app.buttons["playtest-inspector-close"]), "swiped away")

        // Next turn: it can attack, and attacking taps it.
        app.buttons["playtest-end-turn"].tap()
        XCTAssertTrue(app.staticTexts["Turn 2"].waitForExistence(timeout: 3))
        XCTAssertFalse(onTable.label.contains("summoning sick"), onTable.label)
        app.buttons["playtest-attack"].tap()
        let confirm = app.buttons["playtest-attack-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        shot("p08-attack")
        confirm.tap()
        XCTAssertTrue(waitFor(onTable, labelContains: "tapped"), onTable.label)

        // Undo takes the attack back.
        app.buttons["playtest-undo"].tap()
        XCTAssertTrue(waitFor(onTable, labelLacks: "tapped"), onTable.label)

        // The graveyard holds the instant; a tap opens it in the inspector
        // with flashback on offer.
        graveyard.tap()
        let buried = app.descendants(matching: .any)["playtest-zone-\(instantName)"]
        XCTAssertTrue(buried.waitForExistence(timeout: 5))
        shot("p09-graveyard")
        buried.tap()
        let flashback = app.buttons["playtest-inspector-primary"]
        XCTAssertTrue(flashback.waitForExistence(timeout: 5))
        XCTAssertTrue(flashback.label.contains("Flashback"), flashback.label)
        app.buttons["playtest-inspector-close"].tap()
        XCTAssertTrue(waitForGone(flashback), "closed")

        // New game: back to an opening hand.
        app.buttons["playtest-menu"].tap()
        app.buttons["New Game"].tap()
        XCTAssertTrue(app.buttons["New Game"].waitForExistence(timeout: 3))
        app.buttons["New Game"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["playtest-opening"].waitForExistence(timeout: 3))
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
        shot("p10-tokens")
    }

    /// The seeded lands rarely pay for a seeded spell: the table asks.
    private func castAnywayIfAsked(_ app: XCUIApplication) {
        let anyway = app.alerts.buttons["Cast Anyway"]
        if anyway.waitForExistence(timeout: 2) {
            shot("p04a-not-enough-mana")
            anyway.tap()
        }
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
        for _ in 0..<30 {
            if !element.exists { return true }
            usleep(100_000)
        }
        return false
    }

    private func waitFor(_ element: XCUIElement, label: String? = nil, labelContains: String? = nil, labelLacks: String? = nil) -> Bool {
        for _ in 0..<30 {
            let current = element.label
            if let label, current == label { return true }
            if let labelContains, current.contains(labelContains) { return true }
            if let labelLacks, !current.contains(labelLacks) { return true }
            usleep(100_000)
        }
        return false
    }
}
