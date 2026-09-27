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
        app.buttons["scan-settings"].tap()
        XCTAssertTrue(app.navigationBars["Scan Settings"].waitForExistence(timeout: 5))
        shot("s07-settings")
        app.buttons["scan-settings-lock"].tap()
        sleep(3)
        shot("s08-lock-sets")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["scan-settings-done"].tap()
        app.buttons["scan-tray"].tap()
        shot("s09-tray")
        app.buttons["Close"].firstMatch.tap()
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
    }
}
