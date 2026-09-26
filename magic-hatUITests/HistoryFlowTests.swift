//
//  HistoryFlowTests.swift
//  magic-hatUITests
//
//  Undo and redo from the History tab, on the seeded store: a removal is
//  undone (the card is back in the grid) and redone (gone again), then
//  undone once more and followed by a new action — after which there is
//  nothing to redo, and the row stays marked Undone.
//

import XCTest

final class HistoryFlowTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        return app
    }

    private func openCollection(_ app: XCUIApplication) {
        app.tabBars.buttons["Collection"].tap()
        let card = app.staticTexts["Test Collection"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        if app.navigationBars["Test Collection"].exists { return }
        card.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
    }

    @MainActor
    func testUndoRedoARemovalAndAForkClearsRedo() {
        let app = launch()
        openCollection(app)

        // Remove Card 1 from the viewer.
        let tile = app.staticTexts["Card 1"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        let remove = app.buttons["viewer-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS 'from Test Collection'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["3× Card 10"].waitForExistence(timeout: 10), "viewer steps on")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 10))

        // History: Undo is offered, Redo is not.
        app.tabBars.buttons["History"].tap()
        let undo = app.buttons["history-undo"]
        let redo = app.buttons["history-redo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertTrue(undo.isEnabled, "a removal to undo")
        XCTAssertFalse(redo.isEnabled, "nothing to redo yet")
        undo.tap()
        XCTAssertTrue(app.staticTexts["history-undone"].firstMatch.waitForExistence(timeout: 10), "the row is marked Undone")
        XCTAssertTrue(redo.isEnabled)

        // The card is back.
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForExistence(timeout: 10), "undo put the card back")

        // Redo takes it away again.
        app.tabBars.buttons["History"].tap()
        redo.tap()
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 10), "redo removed it again")

        // Undo once more, then a new action: add a copy of Card 0.
        app.tabBars.buttons["History"].tap()
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 10))
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Card 0"].firstMatch.tap()
        let add = app.buttons["viewer-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let addConfirm = app.buttons["add-card-confirm"]
        XCTAssertTrue(addConfirm.waitForExistence(timeout: 10))
        addConfirm.tap()
        app.buttons["add-card-done"].tap()
        XCTAssertTrue(app.staticTexts["2× Card 0"].waitForExistence(timeout: 10))
        app.buttons["viewer-close"].tap()

        // The fork: the undone removal is left behind, nothing to redo.
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(undo.isEnabled, "the add can be undone")
        XCTAssertFalse(redo.isEnabled, "a new action after an undo leaves nothing to redo")
        XCTAssertTrue(app.staticTexts["history-undone"].firstMatch.exists, "the superseded row still reads Undone")
    }
}

private extension XCUIElement {
    func waitForEnabled(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isEnabled { return true }
            usleep(200_000)
        }
        return false
    }
}
