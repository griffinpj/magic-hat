//
//  ScanTour.swift
//  magic-hatUITests
//
//  Screenshots of the scanner's chrome and card panel (`-uitest-scan-demo`,
//  real cards from Scryfall, so the network is needed), its settings, and
//  importing into a list. Written to `TEST_RUNNER_UITEST_SHOT_DIR`; skipped
//  when that isn't set.
//

import XCTest

final class ScanTour: XCTestCase {
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

    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private func shot(_ name: String) {
        usleep(900_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// A Form's Toggle is a switch inside a switch to XCUITest; the inner
    /// one is what flips.
    private func toggleFrame(_ app: XCUIApplication) {
        let row = app.switches["scan-settings-frame"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let inner = row.switches.firstMatch
        if inner.exists { inner.tap() } else { row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
    }

    @MainActor
    func testScanTour() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed", "-uitest-scan-demo"]
        app.launch()

        app.tabBars.buttons["Scan"].tap()
        XCTAssertTrue(app.buttons["scan-plus"].waitForExistence(timeout: 30), "the demo cards arrive from Scryfall")
        sleep(3)
        shot("s01-scanner")
        app.buttons["scan-plus"].tap()
        shot("s02-plus-one")
        app.buttons["scan-printing"].tap()
        sleep(4)
        shot("s03-printings")
        app.buttons["scan-printings-done"].tap()
        app.buttons["scan-finish"].tap()
        shot("s04-finish-menu")
        app.buttons["Foil"].firstMatch.tap()
        app.buttons["scan-language"].tap()
        shot("s05-language-menu")
        app.buttons["Japanese"].firstMatch.tap()
        shot("s06-edited")
        // The name field: what "Not This" and an unreadable card lead to.
        app.buttons["scan-type"].tap()
        let manual = app.textFields["scan-manual-field"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5), "the keyboard button opens the name field")
        manual.typeText("counterspel")
        XCTAssertTrue(app.buttons["scan-manual-result-Counterspell"].waitForExistence(timeout: 20), "Scryfall's matches as you type")
        shot("s06b-type-a-name")
        app.buttons["scan-manual-result-Counterspell"].tap()
        XCTAssertTrue(app.staticTexts["Counterspell"].firstMatch.waitForExistence(timeout: 10), "the typed card is in the tray's head")
        shot("s06c-typed-card-added")
        app.buttons["scan-settings"].tap()
        XCTAssertTrue(app.navigationBars["Scan Settings"].waitForExistence(timeout: 5))
        shot("s07-settings")
        toggleFrame(app)
        app.buttons["scan-settings-done"].tap()
        shot("s07b-with-card-frame")
        app.buttons["scan-settings"].tap()
        toggleFrame(app)
        app.buttons["scan-settings-lock"].tap()
        sleep(3)
        shot("s08-lock-sets")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["scan-settings-done"].tap()
        app.buttons["scan-tray"].tap()
        shot("s09-tray")
        app.buttons["scan-tray-done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("s10-scanner-landscape")
        XCUIDevice.shared.orientation = .portrait

        // Import into a new list.
        app.tabBars.buttons["Collection"].tap()
        app.buttons["collections-menu"].tap()
        app.buttons["new-list-menu"].tap()
        app.alerts.textFields.firstMatch.typeText("Wants")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.navigationBars["Wants"].waitForExistence(timeout: 5))
        shot("s11-empty-list")
        app.buttons["collection-empty-import"].tap()
        let editor = app.textViews["collection-import-text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("4 Card 1\n2 Card 2 *F*\n1 Card 3\n")
        app.swipeDown(velocity: .slow)
        shot("s12-import-sheet")
        app.buttons["collection-import-run"].tap()
        XCTAssertTrue(app.alerts["Imported"].waitForExistence(timeout: 15))
        shot("s13-imported")
        app.alerts.buttons["OK"].tap()
        sleep(2)
        shot("s14-list-filled")
        // A list's rows say when the card is already owned.
        app.staticTexts["Card 1"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'viewer-name' AND label CONTAINS 'In collection'")).firstMatch.waitForExistence(timeout: 5), "In collection, on a list's card")
        shot("s15-list-card-in-collection")
        app.buttons["viewer-close"].tap()
        app.buttons["collection-more"].tap()
        app.buttons["collection-import"].tap()
        let again = app.textViews["collection-import-text"]
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        again.tap()
        again.typeText("Name,Qty,Foil\nCard 5,2,foil\nCard 6,1,\n")
        app.swipeDown(velocity: .slow)
        let format = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Spreadsheet'")).firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 5), "a pasted table is read as one")
        shot("s16-import-table")
        app.swipeUp()
        app.buttons["collection-import-formats"].tap()
        shot("s17-import-formats")
    }
}
