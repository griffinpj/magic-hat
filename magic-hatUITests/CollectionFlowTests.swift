//
//  CollectionFlowTests.swift
//  magic-hatUITests
//
//  Drives the real app against seeded in-memory data (`-uitest-seed`, 900
//  cards, no network) and measures the things that were laggy: entering a
//  collection, scrolling the grid, opening the viewer, pushing detail.
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
    func testOpenViewerAndDetail() {
        let app = launch()
        _ = openCollection(app)

        // Seeded cards have no image, so the tile shows its name.
        let tile = app.staticTexts["Card 0"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()

        let details = app.buttons["viewer-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), "viewer should open with its toolbar")
        details.tap()

        XCTAssertTrue(app.buttons["Versions"].waitForExistence(timeout: 5), "detail should push")
        app.navigationBars["Card 0"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5), "popping detail should return to the viewer")

        let close = app.buttons["viewer-close"]
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "close should dismiss the viewer")
    }

    /// Viewer → Add → Add to collection → Done: the card's quantity goes up
    /// and the viewer's info panel reflects it without leaving the screen.
    @MainActor
    func testAddFromViewerIncrementsQuantity() {
        let app = launch()
        _ = openCollection(app)
        app.staticTexts["Card 0"].firstMatch.tap()

        let add = app.buttons["viewer-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "viewer toolbar")
        add.tap()

        let confirm = app.buttons["add-card-confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "add sheet")
        confirm.tap()
        app.buttons["add-card-done"].tap()

        XCTAssertTrue(app.staticTexts["2× Card 0"].waitForExistence(timeout: 10),
                      "viewer should show the merged quantity")
    }

    /// Viewer → Remove → confirm: the viewer steps to the next card, as
    /// Photos does after a delete, and the removed card is gone from the
    /// grid once the viewer closes.
    @MainActor
    func testRemoveFromViewerDeletesTheCard() {
        let app = launch()
        _ = openCollection(app)
        let tile = app.staticTexts["Card 1"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()

        let remove = app.buttons["viewer-remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()

        // The dialog's button reads "Remove <n> from Test Collection"; the
        // toolbar button is plain "Remove", so match on the collection.
        let confirm = app.buttons.matching(NSPredicate(format: "label CONTAINS 'from Test Collection'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation dialog")
        confirm.tap()

        // Name order puts "Card 10" right after "Card 1"; the seed gives it
        // quantity 1 + 10 % 4.
        XCTAssertTrue(app.staticTexts["3× Card 10"].waitForExistence(timeout: 10),
                      "viewer should step to the neighbour")
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 10),
                      "removed card should leave the grid")
    }

    /// The collection is always a search: the field narrows the grid by
    /// name, the Filters sheet narrows it further (seed: colour = i % 6),
    /// and Clear brings everything back.
    @MainActor
    func testCollectionSearchAndColorFilterNarrowGrid() {
        let app = launch()
        _ = openCollection(app)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Card 12")
        XCTAssertTrue(app.staticTexts["Card 120"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Card 1"].firstMatch.waitForNonExistence(timeout: 5),
                      "only names containing the text remain")

        app.buttons["collection-filters"].tap()
        XCTAssertTrue(app.buttons["filters-done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["filter-group-printings"].exists, "Scryfall-only option hidden")
        app.buttons["Red"].tap()
        app.buttons["filters-done"].tap()

        XCTAssertTrue(app.staticTexts["Card 123"].firstMatch.waitForExistence(timeout: 5), "123 % 6 == 3 → red")
        XCTAssertTrue(app.staticTexts["Card 120"].firstMatch.waitForNonExistence(timeout: 5), "120 % 6 == 0 → white")
        XCTAssertEqual(app.buttons["collection-filters"].value as? String, "1 active")

        app.buttons["collection-clear"].tap()
        XCTAssertTrue(app.staticTexts["Card 0"].firstMatch.waitForExistence(timeout: 5), "everything back")
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
