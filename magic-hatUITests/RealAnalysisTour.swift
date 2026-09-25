//
//  RealAnalysisTour.swift
//  magic-hatUITests
//
//  Not a test of behaviour: the analysis, the recommendations and a card's
//  synergies on the real collection with the network on — every outside
//  source live (Commander Spellbook, Recommander, EDHREC, Scryfall) — with
//  a PNG of each screen for vetting by eye. Runs only when both
//  `TEST_RUNNER_UITEST_SHOT_DIR` and `TEST_RUNNER_UITEST_CSV` are set:
//
//    TEST_RUNNER_UITEST_CSV=/tmp/perf/ManaBox_Collection.csv \
//    TEST_RUNNER_UITEST_SHOT_DIR=/tmp/shots \
//      xcodebuild test … -only-testing:magic-hatUITests/RealAnalysisTour
//
//  The deck is the King Under the Mountain fixture, pasted from the
//  clipboard the way a user pastes a list from a deck site.
//

import XCTest

final class RealAnalysisTour: XCTestCase {
    private var dir: URL?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["UITEST_SHOT_DIR"], !path.isEmpty, let csv = env["UITEST_CSV"], !csv.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_SHOT_DIR and TEST_RUNNER_UITEST_CSV to run the real tour.")
        }
        dir = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        continueAfterFailure = true
    }

    private func shot(_ name: String) {
        guard let dir else { return }
        usleep(800_000)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    private func scroll(until element: XCUIElement, in app: XCUIApplication, up: Bool = true, tries: Int = 8) {
        for _ in 0..<tries where !element.exists {
            if up { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
    }

    @MainActor
    func testRealTour() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-real"]
        let slice = try fixtureURL("default_cards.slice.jsonl.gz").path
        app.launchEnvironment = ["UITEST_IMPORT_CSV": env["UITEST_CSV"]!, "UITEST_RESET": "1", "UITEST_INGEST_FILE": slice]
        app.launch()

        // The import runs at launch; the Collections tab shows the result.
        app.tabBars.buttons["Collection"].tap()
        XCTAssertTrue(app.staticTexts["Real Collection"].waitForExistence(timeout: 180), "the real collection imported")

        // The deck, pasted.
        let list = try String(contentsOf: fixtureURL("KingUnderTheMountain.txt"), encoding: .utf8)
        UIPasteboard.general.string = list
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let name = app.textFields["import-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("King Under the Mountain")
        app.buttons["import-run"].tap()
        let ok = app.buttons["OK"]
        if ok.waitForExistence(timeout: 30) { ok.tap() }
        XCTAssertTrue(app.navigationBars["King Under the Mountain"].waitForExistence(timeout: 60))
        shot("r01-deck")

        // Stats: the summary lands locally, the sources fill in behind it.
        app.segmentedControls["deck-tabs"].buttons["Stats"].tap()
        let summary = app.descendants(matching: .any)["deck-analysis-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        sleep(12)   // combos, game changers, meta
        shot("r02-stats-analysis")
        app.swipeUp(); app.swipeUp()
        shot("r03-stats-mana")
        scroll(until: app.buttons["deck-analysis"].firstMatch, in: app, up: false)
        app.buttons["deck-analysis"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Analysis"].waitForExistence(timeout: 5))
        shot("r04-analysis")
        app.swipeUp()
        shot("r05-analysis-2")
        app.swipeUp()
        shot("r06-analysis-3")
        app.swipeUp()
        shot("r07-analysis-4")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 10))
        let rec = app.buttons["deck-recommendations"].firstMatch
        for _ in 0..<8 where !(rec.exists && rec.isHittable) { app.swipeUp(velocity: .slow) }
        rec.tap()
        XCTAssertTrue(app.navigationBars["Add Cards"].waitForExistence(timeout: 5))
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-add-'")).firstMatch.waitForExistence(timeout: 60)
        shot("r08-recommended-in-add-sheet")
        app.swipeUp()
        shot("r09-recommended-scrolled")
        app.buttons["deck-add-done"].tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 5))
        let swapsRow = app.buttons["deck-swaps"].firstMatch
        for _ in 0..<8 where !(swapsRow.exists && swapsRow.isHittable) { app.swipeUp(velocity: .slow) }
        swapsRow.tap()
        XCTAssertTrue(app.navigationBars["Swaps"].waitForExistence(timeout: 5))
        usleep(800_000)
        shot("r10-swaps")
        app.swipeUp()
        shot("r11-swaps-2")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 10))
        app.segmentedControls["deck-tabs"].buttons["Cards"].tap()
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
        shot("r11b-cards-with-swaps-row")

        // A synergy screen for the first recommended card, then for the commander.
        app.buttons["deck-menu"].tap()
        app.buttons["deck-menu-recommend"].tap()
        XCTAssertTrue(app.navigationBars["Add Cards"].waitForExistence(timeout: 5))
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-row-'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 60))
        firstRow.tap()
        XCTAssertTrue(app.buttons["viewer-synergies"].waitForExistence(timeout: 10))
        shot("r12-viewer-from-recommendation")
        app.buttons["viewer-synergies"].tap()
        XCTAssertTrue(app.navigationBars["Synergies"].waitForExistence(timeout: 5))
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'synergy-row-'")).firstMatch.waitForExistence(timeout: 60)
        shot("r13-synergies")
        app.swipeUp()
        shot("r14-synergies-2")
        app.swipeUp()
        shot("r15-synergies-3")
        app.navigationBars["Synergies"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.buttons["deck-add-done"].waitForExistence(timeout: 5))
        app.buttons["deck-add-done"].tap()
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 10))
        app.segmentedControls["deck-tabs"].buttons["Cards"].tap()
        let commander = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row-'")).firstMatch
        XCTAssertTrue(commander.waitForExistence(timeout: 10))
        commander.tap()
        XCTAssertTrue(app.buttons["viewer-synergies"].waitForExistence(timeout: 10))
        app.buttons["viewer-synergies"].tap()
        XCTAssertTrue(app.navigationBars["Synergies"].waitForExistence(timeout: 5))
        _ = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'synergy-row-'")).firstMatch.waitForExistence(timeout: 60)
        shot("r16-commander-synergies")
        app.swipeUp()
        shot("r17-commander-synergies-2")
    }

    private func fixtureURL(_ name: String) throws -> URL {
        // The unit test fixtures live beside this target in the repo.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("magic-hatTests/Fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing: \(url.path)") }
        return url
    }
}
