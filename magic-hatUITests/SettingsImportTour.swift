//
//  SettingsImportTour.swift
//  magic-hatUITests
//
//  The settings added for syncing and pulling data (defaults for adding,
//  price cadence, cellular for prices and images, the image cache,
//  online signals, automatic catalog updates, Show Prices) and the
//  import wizard's dry run — what an import will do, in rows and copies,
//  before Import is tapped — on a file the test writes and the app opens
//  (`UITEST_WIZARD_FILE`). Show Prices off is checked on the grid: the
//  tile caption keeps the count and drops the price. Screenshots to
//  `UITEST_SHOT_DIR` when set.
//

import XCTest

final class SettingsImportTour: XCTestCase {
    private func shot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["UITEST_SHOT_DIR"], !dir.isEmpty else { return }
        usleep(700_000)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    /// Four rows: Card 0 twice (the seed holds it foil), Card 4 (held
    /// normal), and one printing the seed doesn't have.
    private func writeCSV() throws -> URL {
        let header = "Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency,Added"
        func row(_ binder: String, _ i: Int, qty: Int, id: String? = nil) -> String {
            let sid = id ?? String(format: "00000000-0000-4000-8000-%012d", i)
            return "\(binder),binder,Card \(i),one,Set 0,\(i),normal,common,\(qty),1,\(sid),0.5,false,false,near_mint,en,USD,2024-04-14T23:32:26.393Z"
        }
        let text = ([header, row("Binder A", 0, qty: 2), row("Binder A", 0, qty: 1), row("Binder A", 4, qty: 3),
                     row("Binder B", 999_999, qty: 4, id: "11111111-1111-4111-8111-111111111111")] + [""]).joined(separator: "\r\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wizard-tour.csv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @MainActor
    func testImportPreviewAndDataSettings() throws {
        continueAfterFailure = false
        let csv = try writeCSV()
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-seed"]
        app.launchEnvironment["UITEST_WIZARD_FILE"] = csv.path
        app.launch()

        // The wizard opens on the file: a new collection, every binder.
        let preview = app.descendants(matching: .any)["import-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "the wizard with its dry run")
        XCTAssertTrue(app.staticTexts["Adds 10 copies from 4 rows."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["3 new rows."].exists, "the duplicate printing counts once")
        shot("s01-import-new-collection")

        // Into the seeded collection: Card 4 merges (normal, as the seed
        // holds it); the seed's Card 0 is foil, so the file's normal one is new.
        app.buttons["Existing Collection"].tap()
        XCTAssertTrue(app.staticTexts["2 new rows; 3 copies merge into 1 row you already have."].waitForExistence(timeout: 5))
        shot("s02-import-merge")
        app.buttons["Replace collection"].tap()
        let removes = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Removes '")).firstMatch
        XCTAssertTrue(removes.waitForExistence(timeout: 5), "replace says what it removes first")
        XCTAssertTrue(app.staticTexts["3 new rows."].exists, "nothing merges into an emptied collection")
        shot("s03-import-replace")
        // Only Binder A: the unmatched row drops out.
        app.buttons["Add to collection"].tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Binder B'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Adds 6 copies from 3 rows."].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        // Settings: the data sections.
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 10))
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let showPrices = app.switches["settings-show-prices"].firstMatch
        for _ in 0..<4 where !showPrices.exists { app.swipeUp() }
        XCTAssertTrue(showPrices.exists)
        shot("s04-settings-display")
        let cadence = app.descendants(matching: .any)["settings-price-refresh"]
        for _ in 0..<4 where !cadence.isHittable { app.swipeUp() }
        shot("s05-settings-prices-images")
        cadence.tap()
        XCTAssertTrue(app.buttons["Daily"].waitForExistence(timeout: 5))
        shot("s06-settings-cadence")
        app.buttons["Daily"].tap()
        let auto = app.descendants(matching: .any)["settings-auto-catalog"]
        for _ in 0..<6 where !auto.exists { app.swipeUp() }
        XCTAssertTrue(auto.exists, "the catalog's automatic updates toggle")
        shot("s07-settings-catalog")

        // Data Activity: what runs, when, what it last did; prices running
        // in the seed.
        let activityLink = app.buttons["settings-data-activity"]
        for _ in 0..<4 where !activityLink.isHittable { app.swipeUp() }
        activityLink.tap()
        XCTAssertTrue(app.navigationBars["Data Activity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1,240 of 3,846"].waitForExistence(timeout: 5), "the running price refresh with its progress")
        let catalogRow = app.buttons["data-activity-catalog"]
        XCTAssertTrue(catalogRow.exists)
        XCTAssertTrue(catalogRow.label.contains("3 days ago"), catalogRow.label)
        shot("s07b-data-activity")
        catalogRow.tap()
        XCTAssertTrue(app.staticTexts["Last Run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '112,000 cards · build Sep 29'")).firstMatch.exists)
        shot("s07c-data-activity-catalog")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        // Show Prices off: the grid's captions drop their price.
        for _ in 0..<6 where !showPrices.isHittable { app.swipeDown() }
        flip(showPrices)
        app.buttons["settings-done"].tap()
        app.staticTexts["Test Collection"].tap()
        XCTAssertTrue(app.staticTexts["Card 0"].firstMatch.waitForExistence(timeout: 10))
        let priced = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '$'")).allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertEqual(priced.count, 0, "no price on any caption on screen: \(priced.map(\.label))")
        shot("s08-grid-no-prices")
    }

    /// A Form's Toggle is a switch inside a switch to XCUITest; the inner
    /// one is what flips.
    private func flip(_ row: XCUIElement) {
        let before = row.value as? String
        for _ in 0..<3 {
            let inner = row.switches.firstMatch
            if inner.exists { inner.tap() } else { row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            usleep(400_000)
            if (row.value as? String) != before { return }
        }
        XCTFail("the switch did not flip: \(row.value ?? "nil")")
    }
}
