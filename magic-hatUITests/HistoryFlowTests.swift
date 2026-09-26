//
//  HistoryFlowTests.swift
//  magic-hatUITests
//
//  Undo and redo from the History tab, on the seeded store: a removal is
//  undone (the card is back in the grid) and redone (gone again), then
//  undone once more and followed by a new action — a fork. Undoing that
//  offers both branches (the section, Redo's sheet); the original is
//  taken, and the other branch's detail screen switches back to it.
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
        XCTAssertFalse(redo.isEnabled, "a new action after an undo leaves nothing to redo from here")
        XCTAssertTrue(app.staticTexts["history-undone"].firstMatch.exists, "the other branch still reads Undone")

        // Back to the fork: both branches are ways forward again — as a
        // section at the top of the list, and from Redo as a sheet.
        undo.tap()
        XCTAssertTrue(redo.waitForEnabled(timeout: 10), "at the fork, Redo is back")
        let branches = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history-branch-'"))
        XCTAssertTrue(branches.firstMatch.waitForExistence(timeout: 5), "the fork section lists the branches")
        XCTAssertEqual(branches.count, 2)
        XCTAssertTrue(app.staticTexts["Added Card 0"].firstMatch.exists && app.staticTexts["Removed Card 1"].firstMatch.exists,
                      "rows are named for their cards")
        shot(app, "history-fork")
        redo.tap()
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Removed Card 1'")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), "Redo asks which branch")
        shot(app, "history-fork-sheet")
        original.tap()
        XCTAssertTrue(app.staticTexts["history-busy"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(branches.firstMatch.exists, "one branch taken: no longer a fork")
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 10), "the original branch again: the removal stands")

        // The other branch's row opens its detail; its one button switches.
        app.tabBars.buttons["History"].tap()
        app.staticTexts["Added Card 0"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Added Card 0"].waitForExistence(timeout: 5), "the detail is titled for the action")
        let change = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'history-change-'")).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 10), "the changed card is listed")
        let act = app.buttons["history-detail-action"]
        XCTAssertTrue(act.waitForExistence(timeout: 5))
        XCTAssertTrue(act.label.contains("Switch to This Branch"), "undone on the other branch: \(act.label)")
        shot(app, "history-detail")
        act.tap()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !act.label.contains("Undo This Action") { usleep(200_000) }
        XCTAssertTrue(act.label.contains("Undo This Action"), "switched: the action stands, so the button undoes it")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForExistence(timeout: 10), "the removal is undone on this branch")
        app.staticTexts["Card 0"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["2× Card 0"].waitForExistence(timeout: 10), "and the add applied")
        app.buttons["viewer-close"].tap()
    }

    /// A PNG under `TEST_RUNNER_UITEST_SHOT_DIR` when set, as the tour writes them.
    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
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
