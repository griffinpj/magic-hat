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

        // Add from the collection search: a sheet over the deck.
        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["deck-search-filters"].waitForExistence(timeout: 5), "filters in the sheet's bar")
        XCTAssertTrue(app.buttons["deck-add-done"].exists, "Done in the sheet's bar")
        field.tap()
        field.typeText("Card 120")
        let add = app.buttons["deck-search-add-Card 120"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "collection search result")
        add.tap()
        XCTAssertTrue(app.buttons["deck-search-minus-Card 120"].waitForExistence(timeout: 5), "the row becomes a stepper once in")
        // The viewer opens from a result *on that card*, with the same
        // stepper in its bar. It came up empty once: the presentation read
        // a stale copy of the sheet's state inside the active search session.
        app.buttons["deck-search-row-Card 120"].tap()
        XCTAssertTrue(app.navigationBars["Card 120"].waitForExistence(timeout: 5), "viewer shows the tapped card")
        XCTAssertTrue(app.buttons["viewer-deck-plus"].exists, "viewer steps the deck count")
        app.buttons["viewer-deck-plus"].tap()
        XCTAssertTrue(app.staticTexts["viewer-deck-count"].waitForLabel(prefix: "2 in", timeout: 5), "count follows the deck")
        app.buttons["viewer-deck-minus"].tap()
        XCTAssertTrue(app.staticTexts["viewer-deck-count"].waitForLabel(prefix: "1 in", timeout: 5))
        XCTAssertFalse(app.buttons["viewer-remove"].exists, "nothing to remove from a search result")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.buttons["deck-add-done"].waitForExistence(timeout: 5))

        // The sort button: "Card 12" matches Card 12 and Card 120–129,
        // priced 12 and 20–29 in the seed. Relevance leads with the exact
        // name; Price (High) with Card 129.
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-row-'"))
        XCTAssertTrue(rows.element(boundBy: 0).waitForIdentifier("deck-search-row-Card 12", timeout: 5), "relevance: the exact name first")
        app.buttons["deck-search-sort"].tap()
        XCTAssertTrue(app.buttons["Price (High)"].waitForExistence(timeout: 5))
        app.buttons["Price (High)"].tap()
        XCTAssertTrue(rows.element(boundBy: 0).waitForIdentifier("deck-search-row-Card 129", timeout: 5), "priciest first")
        app.buttons["deck-add-done"].tap()
        XCTAssertTrue(app.navigationBars["UI Deck"].waitForExistence(timeout: 5), "Done returns to the deck, not the Decks tab")
        XCTAssertTrue(app.segmentedControls["deck-tabs"].exists, "section picker never left")

        let row = app.buttons["deck-row-Card 120"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the card is on the list")

        // The sections are pages: a swipe moves between them like the picker.
        app.swipeLeft()
        XCTAssertTrue(app.staticTexts["Average mana value"].waitForExistence(timeout: 5), "swiping left lands on Stats")
        app.swipeRight()
        XCTAssertTrue(app.buttons["deck-row-Card 120"].firstMatch.waitForExistence(timeout: 5), "swiping right returns to Cards")

        // Export is a sheet of options with a live preview, not a bare share.
        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-export"].tap()
        let preview = app.staticTexts["export-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "export preview")
        XCTAssertTrue(preview.label.contains("// MAINBOARD") && preview.label.contains("1 Card 120 (ONE) 120"), preview.label)
        XCTAssertTrue(app.buttons["export-share-text"].exists && app.buttons["export-share-file"].exists && app.buttons["export-copy"].exists)
        // A Form toggle's element is the whole row; the switch is at its
        // trailing edge, and a tap in the middle lands on the label.
        let missing = app.switches["export-missing"].firstMatch
        missing.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(missing.waitForValue(containing: "1", timeout: 5), "toggle on: \(missing.value ?? "")")
        XCTAssertTrue(app.staticTexts["Nothing to export with these options."].waitForExistence(timeout: 5),
                      "an available card is not missing, so nothing is")
        app.buttons["export-cancel"].tap()
        XCTAssertTrue(app.buttons["deck-row-Card 120"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue((row.value as? String)?.contains("In collection") == true, "available, not yet built: \(row.value ?? "")")
        row.tap()
        XCTAssertTrue(app.navigationBars["Card 120"].waitForExistence(timeout: 5), "viewer from a deck row")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.navigationBars["UI Deck"].waitForExistence(timeout: 5))

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
        let built = app.buttons["deck-row-Card 120"].firstMatch
        XCTAssertTrue(built.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(built, containing: "In deck"), "built")

        // A built deck's hidden collection never shows up as a collection.
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Test Collection"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'deck:'")).firstMatch.exists,
                       "no deck: collection listed")
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["UI Deck"].waitForExistence(timeout: 5))

        // Disassemble: back to the collection.
        app.buttons["deck-menu"].tap()
        app.buttons["Disassemble Deck…"].tap()
        let back = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Move'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(waitForValue(app.buttons["deck-row-Card 120"].firstMatch, containing: "In collection"), "returned")

        // Lock: no stepper, no adding.
        app.buttons["deck-menu"].tap()
        app.buttons["Lock Deck"].tap()
        XCTAssertTrue(app.buttons["Fewer Card 120"].waitForNonExistence(timeout: 5), "no editing while locked")
        XCTAssertFalse(app.buttons["deck-add-cards"].isEnabled, "no adding while locked")

        // The screen's field filters the list, and searching from another
        // tab brings Cards back; Back steps aside while the session is on.
        app.segmentedControls["deck-tabs"].buttons["Stats"].tap()
        let filter = app.searchFields.firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "filter field on every tab")
        filter.tap()
        XCTAssertTrue(app.buttons["BackButton"].waitForNonExistence(timeout: 5), "Back hidden while searching")
        filter.typeText("Card 120")
        XCTAssertTrue(app.buttons["deck-row-Card 120"].firstMatch.waitForExistence(timeout: 5), "searching shows Cards")
        filter.buttons["Clear text"].tap()
        filter.typeText("Nothing here")
        let noResults = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch
        XCTAssertTrue(noResults.waitForExistence(timeout: 5), "filter narrows the deck")
        XCTAssertTrue(app.navigationBars["UI Deck"].exists, "still on the deck")
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
        let five = app.buttons["deck-row-Card 5"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        XCTAssertTrue((five.value as? String)?.hasPrefix("2,") == true, "two copies: \(five.value ?? "")")
        XCTAssertTrue(app.buttons["deck-row-Card 3"].firstMatch.exists, "the commander")
        // Card 7 is blue and the commander is red: the list leads with the
        // rule broken, and the row leads to the full check on Stats.
        let issues = app.buttons["deck-issues"]
        XCTAssertTrue(issues.waitForExistence(timeout: 5), "issues row")
        XCTAssertTrue(issues.label.contains("1 outside colour identity"), issues.label)
        // The row right after the commander opens the viewer on *itself*.
        // It opened on the commander: the pager's initial position scrolled
        // only until the card was visible, and the second card already
        // peeked in at the edge.
        app.buttons["deck-row-Card 5"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Card 5"].waitForExistence(timeout: 5), "viewer opens on the second row, not the commander")
        app.buttons["viewer-close"].tap()
        // And a row further down, which always worked.
        app.buttons["deck-row-Card 7"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Card 7"].waitForExistence(timeout: 5), "viewer opens on the tapped row")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        issues.tap()
        XCTAssertTrue(app.staticTexts["Card 7 is outside the commander's colour identity"].waitForExistence(timeout: 5), "Stats lists the issue")
    }

    /// The analysis, the recommendations and a card's synergies on the
    /// seeded store: the local reading is there without a network, every
    /// outside source says it needs one, and a recommendation's "+" puts
    /// the card on the list like the add sheet's does.
    @MainActor
    func testAnalysisRecommendationsAndSynergiesOffline() {
        let app = launchOnDecks()
        var list = "// COMMANDER\n1 Card 3\n\n"
        for i in stride(from: 9, to: 120, by: 6) { list += "1 Card \(i)\n" }   // red and colourless: identity-safe
        UIPasteboard.general.string = list
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let name = app.textFields["import-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Analysis Deck")
        app.buttons["import-run"].tap()
        XCTAssertTrue(app.navigationBars["Analysis Deck"].waitForExistence(timeout: 15))

        // Stats leads with the analysis: scores, then the full reading.
        selectSection(app, "Stats")
        let summary = app.descendants(matching: .any)["deck-analysis-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the local reading lands without a network")
        app.buttons["deck-analysis"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Analysis"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["analysis-scores"].waitForExistence(timeout: 5), "three scores")
        XCTAssertTrue(app.descendants(matching: .any)["analysis-bracket"].exists, "a bracket for a commander deck")
        // The list is lazy: rows below the fold are not in the tree until scrolled to.
        let offline = app.staticTexts["Combos need a connection."]
        for _ in 0..<8 where !offline.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(offline.waitForExistence(timeout: 5), "offline is said, not hidden")
        app.navigationBars["Analysis"].buttons.firstMatch.tap()

        // Recommended cards live in the add sheet, as a scope of their own;
        // the Stats row opens the sheet there. "+" adds to the list.
        let recRow = app.buttons["deck-recommendations"].firstMatch
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5), "back on the deck")
        for _ in 0..<8 where !(recRow.exists && recRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(recRow.waitForExistence(timeout: 5))
        recRow.tap()
        XCTAssertTrue(app.navigationBars["Add Cards"].waitForExistence(timeout: 5), "the add sheet")
        XCTAssertTrue(app.segmentedControls["deck-search-scope"].buttons["Recommended"].isSelected, "opened on Recommended")
        let add = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-add-'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 20), "the collection offers a card once the plan lands")
        let cardName = add.identifier.replacingOccurrences(of: "deck-search-add-", with: "")
        add.tap()
        XCTAssertTrue(app.buttons["deck-search-minus-\(cardName)"].waitForExistence(timeout: 5), "the row becomes a stepper once in")
        app.buttons["deck-add-done"].tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))
        // The swap table, from the Stats row.
        let swapsRow = app.buttons["deck-swaps"].firstMatch
        for _ in 0..<8 where !(swapsRow.exists && swapsRow.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(swapsRow.waitForExistence(timeout: 5))
        swapsRow.tap()
        XCTAssertTrue(app.navigationBars["Swaps"].waitForExistence(timeout: 5))
        // A short list gets adds; a full one swaps or cuts; a tuned one nothing.
        let swapsPage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Add ·' OR label == 'Swaps' OR label == 'Cut' OR label == 'Nothing to Swap'")).firstMatch
        XCTAssertTrue(swapsPage.waitForExistence(timeout: 20), "the swap table has a page of its own")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))
        selectSection(app, "Cards")
        // The list is lazy and sorted by name within each type; scroll to find rows.
        let added = app.buttons["deck-row-\(cardName)"].firstMatch
        for _ in 0..<8 where !added.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the recommendation is on the list")
        // Back to the top, then the second creature: the first sits under
        // the pinned "Creatures" header when the list is scrolled, and a
        // tap on its centre lands on the header.
        for _ in 0..<8 { app.swipeDown(velocity: .fast) }
        usleep(600_000)   // let the list settle: a tap mid-deceleration only stops the scroll
        let second = app.buttons["deck-row-Card 111"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 5))

        // A card's synergies from the viewer, pushed like Details.
        second.tap()
        if !app.navigationBars["Card 111"].waitForExistence(timeout: 5) { shot("flow-viewer-miss"); second.tap() }
        XCTAssertTrue(app.navigationBars["Card 111"].waitForExistence(timeout: 5))
        app.buttons["viewer-synergies"].tap()
        XCTAssertTrue(app.navigationBars["Synergies"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Needs a connection."].firstMatch.waitForExistence(timeout: 5), "every source says so offline")
        app.navigationBars["Synergies"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.navigationBars["Analysis Deck"].waitForExistence(timeout: 5))
    }

    /// Taps a section of the deck screen and waits until the paged TabView
    /// has actually moved there: a tap that lands mid-pop-animation is lost,
    /// and the other page's rows are still in the tree meanwhile.
    private func selectSection(_ app: XCUIApplication, _ name: String) {
        let button = app.segmentedControls["deck-tabs"].buttons[name]
        for _ in 0..<3 where !button.isSelected {
            button.tap()
            usleep(600_000)
        }
        XCTAssertTrue(button.isSelected, "\(name) selected")
    }

    /// A PNG for diagnosing a failed step, when `UITEST_SHOT_DIR` is set.
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func waitForValue(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 8) -> Bool {
        return element.waitForValue(containing: text, timeout: timeout)
    }
}

extension XCUIElement {
    func waitForLabel(prefix: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, label.hasPrefix(prefix) { return true }
            usleep(200_000)
        }
        return false
    }

    func waitForValue(containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (value as? String)?.contains(text) == true { return true }
            usleep(200_000)
        }
        return false
    }
}

private extension XCUIElement {
    /// Polls until the element's identifier is `identifier` (a list's
    /// first row changes in place when it re-sorts).
    func waitForIdentifier(_ identifier: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, self.identifier == identifier { return true }
            usleep(200_000)
        }
        return false
    }
}
