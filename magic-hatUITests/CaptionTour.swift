//
//  CaptionTour.swift
//  magic-hatUITests
//
//  Screenshots of the card grid's glass caption and the viewer's price
//  trend on the real collection, with its art and prices: launches
//  `-uitest-real` on the ManaBox export, waits for metadata and images,
//  and writes PNGs to `TEST_RUNNER_UITEST_SHOT_DIR`. Needs the network;
//  skipped unless both the CSV and the shot directory are given.
//
//    TEST_RUNNER_UITEST_CSV=… TEST_RUNNER_UITEST_SHOT_DIR=… xcodebuild test …
//      -only-testing:magic-hatUITests/CaptionTour
//

import XCTest

final class CaptionTour: XCTestCase {
    private var dir: URL!
    private var csv = ""

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let csv = env["UITEST_CSV"], !csv.isEmpty, let path = env["UITEST_SHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_CSV and TEST_RUNNER_UITEST_SHOT_DIR.")
        }
        self.csv = csv
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private func shot(_ name: String) {
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
    }

    @MainActor
    func testCaptions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-real"]
        app.launchEnvironment["UITEST_IMPORT_CSV"] = csv
        app.launchEnvironment["UITEST_RESET"] = "1"
        app.launch()

        let collection = app.buttons["collection-Real Collection"]
        XCTAssertTrue(collection.waitForExistence(timeout: 120))
        collection.tap()
        // Metadata for 3,800 rows at Scryfall's pace, then the images.
        let syncing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Syncing'")).firstMatch
        _ = syncing.waitForExistence(timeout: 10)
        _ = syncing.waitForNonExistence(timeout: 240)
        sleep(8)
        shot("c01-grid")
        app.swipeUp(velocity: .slow)
        sleep(5)
        shot("c02-grid-scrolled")

        // Sorted by price, the pricey cards and their trends first.
        app.buttons["sort-button"].tap()
        app.buttons["Price (High)"].firstMatch.tap()
        sleep(6)
        shot("c03-grid-by-price")

        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.32)).tap()
        _ = app.buttons["viewer-close"].waitForExistence(timeout: 10)
        sleep(4)
        shot("c04-viewer")
        app.swipeLeft()
        sleep(3)
        shot("c05-viewer-next")
        app.buttons["viewer-close"].tap()

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(4)
        shot("c06-grid-landscape")
    }
}
