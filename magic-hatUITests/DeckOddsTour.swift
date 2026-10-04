//
//  DeckOddsTour.swift
//  magic-hatUITests
//
//  The odds tools on a seeded deck with a mana base: Goldfish runs and
//  lands its headline numbers, Draw Odds combines two chosen cards, Mana
//  Base reads the lands, each has its "i", and Find a Commander opens
//  from the Decks tab and says so without a network.
//

import XCTest

final class DeckOddsTour: XCTestCase {
    private var dir: URL? {
        guard let path = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// A PNG of the screen, when `UITEST_SHOT_DIR` is set, for vetting by eye.
    private func shot(_ name: String) {
        guard let dir else { return }
        usleep(600_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testOddsToolsAndCommanderFinder() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))

        // A deck with spells and the seed's basic lands (every 15th card).
        var list = "// COMMANDER\n1 Card 3\n\n"
        for i in stride(from: 9, to: 120, by: 6) { list += "1 Card \(i)\n" }
        for i in stride(from: 14, to: 450, by: 15) { list += "1 Card \(i)\n" }
        UIPasteboard.general.string = list
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let name = app.textFields["import-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Odds Deck")
        app.buttons["import-run"].tap()
        XCTAssertTrue(app.navigationBars["Odds Deck"].waitForExistence(timeout: 15))

        let stats = app.segmentedControls["deck-tabs"].buttons["Stats"]
        for _ in 0..<3 where !stats.isSelected { stats.tap(); usleep(600_000) }
        XCTAssertTrue(stats.isSelected)

        // Goldfish: the simulation runs and the headline lands.
        let goldfish = app.buttons["deck-goldfish"].firstMatch
        for _ in 0..<8 where !(goldfish.exists && goldfish.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(goldfish.waitForExistence(timeout: 5))
        goldfish.tap()
        XCTAssertTrue(app.navigationBars["Goldfish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["goldfish-land-drops"].waitForExistence(timeout: 20), "5,000 games land")
        XCTAssertTrue(app.descendants(matching: .any)["goldfish-commander"].exists, "a commander deck reports its commander")
        shot("odds-01-goldfish")
        app.swipeUp(velocity: .slow)
        shot("odds-02-goldfish-charts")
        app.buttons["tool-guide"].tap()
        XCTAssertTrue(app.navigationBars["About Goldfish"].waitForExistence(timeout: 5), "the i explains it")
        shot("odds-03-goldfish-guide")
        app.buttons["Done"].tap()
        app.navigationBars["Goldfish"].buttons.firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))

        // Draw Odds: the lands' split, and two rows combined.
        let draw = app.buttons["deck-draw-odds"].firstMatch
        for _ in 0..<8 where !(draw.exists && draw.isHittable) { app.swipeUp(velocity: .slow) }
        draw.tap()
        XCTAssertTrue(app.navigationBars["Draw Odds"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["odds-keepable"].waitForExistence(timeout: 10))
        let first = app.buttons["odds-row-Card 9"].firstMatch
        for _ in 0..<8 where !(first.exists && first.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        let second = app.buttons["odds-row-Card 93"].firstMatch
        for _ in 0..<4 where !(second.exists && second.isHittable) { app.swipeUp(velocity: .slow) }
        second.tap()
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.descendants(matching: .any)["odds-any"].waitForExistence(timeout: 5), "any of the two")
        XCTAssertTrue(app.descendants(matching: .any)["odds-all"].exists, "all of the two")
        shot("odds-04-draw-odds")
        app.navigationBars["Draw Odds"].buttons.firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))

        // Mana Base: the land count and a colour line.
        let mana = app.buttons["deck-mana-base"].firstMatch
        for _ in 0..<8 where !(mana.exists && mana.isHittable) { app.swipeUp(velocity: .slow) }
        mana.tap()
        XCTAssertTrue(app.navigationBars["Mana Base"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["manabase-lands"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'manabase-'")).count >= 2, "at least one colour line")
        shot("odds-05-mana-base")
        app.swipeUp(velocity: .slow)
        shot("odds-06-mana-base-sources")
        app.navigationBars["Mana Base"].buttons.firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))

        // Find a Commander, from the Decks tab; no network in a seeded run.
        app.navigationBars["Odds Deck"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 5))
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-finder"].tap()
        XCTAssertTrue(app.navigationBars["Find a Commander"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5), "says it could not reach EDHREC")
        shot("odds-07-finder")
        app.buttons["tool-guide"].tap()
        XCTAssertTrue(app.navigationBars["About Find a Commander"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }
}
