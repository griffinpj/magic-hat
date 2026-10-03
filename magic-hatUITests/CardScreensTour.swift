//
//  CardScreensTour.swift
//  magic-hatUITests
//
//  Screenshots of the card viewer and the detail screen on the real store
//  (`-uitest-real`, kept from a RealCollectionTests run), for vetting their
//  design with real art. Written to `TEST_RUNNER_UITEST_SHOT_DIR`;
//  skipped when that isn't set.
//

import XCTest

final class CardScreensTour: XCTestCase {
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

    private func shot(_ name: String) {
        usleep(900_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testViewerAndDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-real"]
        if let csv = ProcessInfo.processInfo.environment["UITEST_CSV"] { app.launchEnvironment["UITEST_IMPORT_CSV"] = csv }
        app.launch()
        let card = app.buttons["collection-Real Collection"]
        XCTAssertTrue(card.waitForExistence(timeout: 120))
        card.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
        sleep(4)
        shot("d00-grid")
        // The first tile.
        app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.22)).tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 10))
        sleep(3)
        shot("d01-viewer")
        app.buttons["viewer-details"].tap()
        sleep(4)
        shot("d02-detail-top")
        app.swipeUp()
        shot("d03-detail-mid")
        app.swipeUp()
        shot("d04-detail-lower")
        app.swipeUp()
        shot("d05-detail-bottom")
        for _ in 0..<3 { app.swipeDown() }
        let rulings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rulings'")).firstMatch
        if rulings.waitForExistence(timeout: 3) { rulings.tap(); sleep(2); shot("d06-detail-rulings") }
    }
}
