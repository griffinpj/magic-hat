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

    /// Overlay → Add → Add to collection → Done: the card's quantity goes up
    /// and the overlay's info card reflects it without leaving the screen.
    @MainActor
    func testAddFromOverlayIncrementsQuantity() {
        let app = launch()
        _ = openCollection(app)
        app.staticTexts["Card 0"].firstMatch.tap()

        let add = app.buttons["overlay-plus.rectangle.on.rectangle"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "overlay action bar")
        add.tap()

        let confirm = app.buttons["add-card-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "add sheet")
        confirm.tap()
        app.buttons["add-card-done"].tap()

        XCTAssertTrue(app.staticTexts["2× Card 0"].waitForExistence(timeout: 10),
                      "overlay should show the merged quantity")
    }

    /// Overlay → trash → confirm: the card leaves the grid.
    @MainActor
    func testRemoveFromOverlayDeletesTheCard() {
        let app = launch()
        _ = openCollection(app)
        let tile = app.staticTexts["Card 1"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()

        let trash = app.buttons["overlay-trash"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.tap()

        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 10),
                      "removed card should leave the grid")
    }

    /// Pick "Price (High)" from the sort menu: the grid should jump to the top
    /// of the new order. In the seed, price = index % 50, so the priciest tier
    /// is 49 and its alphabetically-first name is "Card 149".
    @MainActor
    func testSortByPriceReordersGridFromTheTop() {
        let app = launch()
        let grid = openCollection(app)
        grid.swipeUp(velocity: .fast)   // move away from the top first

        let sort = app.buttons["sort-button"]
        XCTAssertTrue(sort.waitForExistence(timeout: 5))
        sort.tap()
        let price = app.buttons["Price (High)"]
        XCTAssertTrue(price.waitForExistence(timeout: 5), "sort menu")
        price.tap()

        XCTAssertTrue(app.staticTexts["Card 149"].firstMatch.waitForExistence(timeout: 10),
                      "top of the grid should show the highest-priced card")
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
