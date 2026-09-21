//
//  CollectionFlowTests.swift
//  magic-hatUITests
//
//  Drives the real app against seeded in-memory data (`-uitest-seed`, 900
//  cards, no network) and measures the things that were laggy: entering a
//  collection, scrolling the grid, opening the overlay, pushing detail.
//
//  The scroll test uses XCTOSSignpostMetric.scrollDecelerationMetric, which
//  is Apple's own hitch counter for scroll views — the first run records a
//  baseline, later runs fail if hitches regress past it.
//

import XCTest

final class CollectionFlowTests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launch()
        return app
    }

    private func openCollection(_ app: XCUIApplication) -> XCUIElement {
        let card = app.staticTexts["Test Collection"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "collection card should appear")
        card.tap()
        let grid = app.scrollViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "grid should appear")
        return grid
    }

    @MainActor
    func testOpenCollectionOverlayAndDetail() {
        let app = launch()
        _ = openCollection(app)

        // Seeded cards have no image, so the tile shows its name.
        let tile = app.staticTexts["Card 0"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()

        let eye = app.buttons["overlay-eye"]
        XCTAssertTrue(eye.waitForExistence(timeout: 5), "overlay should open with an action bar")
        eye.tap()

        XCTAssertTrue(app.navigationBars["Card 0"].waitForExistence(timeout: 5), "detail should push")
        app.navigationBars["Card 0"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(eye.waitForExistence(timeout: 5), "popping detail should return to the overlay")
    }

    @MainActor
    func testGridScrollDoesNotHitch() {
        let app = launch()
        let grid = openCollection(app)

        measure(metrics: [XCTOSSignpostMetric.scrollDecelerationMetric, XCTMemoryMetric(application: app)]) {
            for _ in 0..<5 { grid.swipeUp(velocity: .fast) }
            for _ in 0..<5 { grid.swipeDown(velocity: .fast) }
        }
    }

    @MainActor
    func testEnteringCollectionIsFast() {
        let app = launch()
        let card = app.staticTexts["Test Collection"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))

        measure(metrics: [XCTClockMetric()]) {
            card.tap()
            XCTAssertTrue(app.staticTexts["Card 0"].firstMatch.waitForExistence(timeout: 10))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
        }
    }
}
