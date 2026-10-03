//
//  DeckVersionFlowTests.swift
//  magic-hatUITests
//
//  A deck's Versions screen on the seeded store: the list starts unsaved,
//  a version is saved and named, an edit shows as unsaved changes and its
//  diff, a branch takes it, switching back restores Main's list, and an
//  older version's page restores it as a new version. Screenshots go to
//  `TEST_RUNNER_UITEST_SHOT_DIR` when it is set.
//

import XCTest

final class DeckVersionFlowTests: XCTestCase {
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        usleep(700_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    private func addCards(_ app: XCUIApplication, search: String, _ cards: [String]) {
        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(search)
        for card in cards {
            let add = app.buttons["deck-search-add-\(card)"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), card)
            add.tap()
        }
        app.buttons["deck-add-done"].tap()
    }

    private func openVersions(_ app: XCUIApplication) {
        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-versions"].tap()
        XCTAssertTrue(app.navigationBars["Versions"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSaveBranchSwitchAndRestore() {
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
        name.typeText("Versioned")
        app.descendants(matching: .any)["newdeck-format"].tap()
        app.buttons["Casual"].tap()
        app.buttons["newdeck-create"].tap()
        XCTAssertTrue(app.navigationBars["Versioned"].waitForExistence(timeout: 10))
        addCards(app, search: "Card 12", ["Card 12", "Card 120", "Card 121"])

        // Nothing saved yet: the whole list is unsaved, and Save is offered.
        openVersions(app)
        XCTAssertTrue(app.descendants(matching: .any)["versions-unsaved"].waitForExistence(timeout: 5))
        shot("v01-unsaved-first")
        app.buttons["versions-save"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("First draft")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["versions-clean"].waitForExistence(timeout: 5), "saved: nothing unsaved")
        XCTAssertTrue(app.staticTexts["First draft"].firstMatch.exists, "the version is listed by its name")
        XCTAssertFalse(app.buttons["versions-save"].exists, "nothing to save, no Save button")
        shot("v02-saved")

        // The "i": how it works, and how it differs from History.
        app.buttons["versions-info"].tap()
        XCTAssertTrue(app.navigationBars["About Versions"].waitForExistence(timeout: 5))
        shot("v02b-guide")
        for _ in 0..<6 where !app.staticTexts["Versions and the History Tab"].exists { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Versions and the History Tab"].exists, "the guide sets the two side by side")
        shot("v02c-guide-compared")
        app.buttons["versions-guide-done"].tap()

        // Edit the list: the change shows, with its diff.
        app.navigationBars.buttons.firstMatch.tap()
        addCards(app, search: "Card 13", ["Card 13", "Card 130"])
        openVersions(app)
        let unsaved = app.descendants(matching: .any)["versions-unsaved"]
        XCTAssertTrue(unsaved.waitForExistence(timeout: 5))
        shot("v03-unsaved-changes")
        unsaved.tap()
        XCTAssertTrue(app.navigationBars["Unsaved Changes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["version-change-Card 13"].waitForExistence(timeout: 5), "the added card is listed")
        shot("v04-unsaved-diff")
        app.navigationBars.buttons.firstMatch.tap()

        // A branch takes the unsaved changes along; save them there.
        app.buttons["versions-new-branch"].tap()
        let branchField = app.alerts.textFields.firstMatch
        XCTAssertTrue(branchField.waitForExistence(timeout: 5))
        branchField.typeText("Budget")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["versions-branch-Budget"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["versions-switch-Main"].waitForExistence(timeout: 5), "Main is the other branch now")
        app.buttons["versions-save"].tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 5))
        app.alerts.textFields.firstMatch.typeText("Two more")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Two more"].firstMatch.waitForExistence(timeout: 5))
        shot("v05-on-branch")

        // Back to Main: its list, and Budget as a branch with versions of its own.
        app.buttons["versions-switch-Main"].tap()
        XCTAssertTrue(app.buttons["versions-switch-Budget"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Two more"].firstMatch.waitForNonExistence(timeout: 5), "Main's versions, not Budget's")
        shot("v06-back-on-main")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Card 12"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Card 130"].exists, "Main's list has no Card 130")

        // Budget again, then restore the first version from its page.
        openVersions(app)
        app.buttons["versions-switch-Budget"].tap()
        XCTAssertTrue(app.staticTexts["Two more"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["First draft"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Version"].waitForExistence(timeout: 5))
        shot("v07-version-page")
        app.buttons["version-menu"].tap()
        shot("v08-version-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()   // dismiss the menu
        let restore = app.buttons["version-restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        let confirm = app.buttons["Restore"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "restoring asks first")
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Versions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Restored “First draft”"].firstMatch.waitForExistence(timeout: 5), "a new version on top, nothing rewound")
        XCTAssertTrue(app.staticTexts["Two more"].firstMatch.exists)
        shot("v09-restored")
    }

    /// A built deck follows its list: Switch asks first, takes the deck
    /// apart and builds the other branch — and History shows both steps.
    @MainActor
    func testSwitchingABuiltDeckRebuildsIt() {
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
        name.typeText("Built One")
        app.descendants(matching: .any)["newdeck-format"].tap()
        app.buttons["Casual"].tap()
        app.buttons["newdeck-create"].tap()
        XCTAssertTrue(app.navigationBars["Built One"].waitForExistence(timeout: 10))
        addCards(app, search: "Card 12", ["Card 12", "Card 120"])

        // Main: two cards, saved. Wide: a third, saved.
        openVersions(app)
        app.buttons["versions-save"].tap()
        app.alerts.textFields.firstMatch.typeText("Two")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["versions-clean"].waitForExistence(timeout: 5))
        app.buttons["versions-new-branch"].tap()
        app.alerts.textFields.firstMatch.typeText("Wide")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["versions-switch-Main"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        addCards(app, search: "Card 13", ["Card 130"])
        openVersions(app)
        app.buttons["versions-save"].tap()
        app.alerts.textFields.firstMatch.typeText("Three")
        app.alerts.buttons["Save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["versions-clean"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()

        // Build Wide's three cards.
        app.buttons["deck-menu"].tap()
        app.buttons["Build from Collection…"].tap()
        let cont = app.buttons["build-continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 10))
        cont.tap()
        let confirm = app.buttons["build-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let done = app.buttons["build-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15))
        done.tap()

        // Switch to Main: it asks, since cards will move.
        openVersions(app)
        shot("v10-built-versions")
        app.buttons["versions-switch-Main"].tap()
        let rebuild = app.buttons["Switch and Rebuild"].firstMatch
        XCTAssertTrue(rebuild.waitForExistence(timeout: 5), "a built deck asks before switching")
        shot("v11-switch-built-confirm")
        rebuild.tap()
        XCTAssertTrue(app.buttons["versions-switch-Wide"].waitForExistence(timeout: 15), "on Main now")
        shot("v12-rebuilt")

        // History: taken apart, then built again.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Disassembled Built One"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == 'Built Built One'")).count, 2, "the first build and the rebuild")
        shot("v13-history-after-rebuild")
    }
}
