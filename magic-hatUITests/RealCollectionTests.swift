//
//  RealCollectionTests.swift
//  magic-hatUITests
//
//  The app as a real user has it: the real ManaBox export on disk, the
//  network on — metadata hydrating, prices refreshing, card images
//  streaming — and the main thread watched. Every flow that felt slow runs
//  here against that, and any main-thread stall over 100ms (six dropped
//  frames) during a step fails the test with the sampled stack, so the
//  cause is in the failure message rather than guessed at.
//
//  Needs two things from the environment, and is skipped without them:
//    TEST_RUNNER_UITEST_CSV=/path/to/ManaBox_Collection.csv
//    TEST_RUNNER_UITEST_PERF_DIR=/path/to/a/writable/dir   (hang logs)
//
//  The store is kept between launches (a first launch imports the export,
//  every later one opens an existing collection); UITEST_RESET wipes it.
//

import XCTest

final class RealCollectionTests: XCTestCase {
    private var csv = ""
    private var hangLog: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let csv = env["UITEST_CSV"], !csv.isEmpty, let dir = env["UITEST_PERF_DIR"], !dir.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_UITEST_CSV and TEST_RUNNER_UITEST_PERF_DIR to run against the real collection.")
        }
        self.csv = csv
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let stem = name.filter { $0.isLetter || $0.isNumber }
        hangLog = URL(fileURLWithPath: dir).appendingPathComponent("hangs-\(stem).jsonl")
        try? FileManager.default.removeItem(at: hangLog)
        // An audit: keep going and report every stall, not just the first.
        continueAfterFailure = true
    }

    private func launch(reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest-real"]
        app.launchEnvironment["UITEST_IMPORT_CSV"] = csv
        app.launchEnvironment["UITEST_HANG_LOG"] = hangLog.path
        // `TEST_RUNNER_UITEST_HANG_THRESHOLD` lowers the bar for an audit
        // (0.05 is three dropped frames); 100ms is the pass/fail line.
        app.launchEnvironment["UITEST_HANG_THRESHOLD"] = ProcessInfo.processInfo.environment["UITEST_HANG_THRESHOLD"] ?? "0.1"
        if reset { app.launchEnvironment["UITEST_RESET"] = "1" }
        app.launch()
        return app
    }

    /// The collection card on the Collections tab; on a fresh store this
    /// waits for the import to land.
    private func collectionCard(_ app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons["Collection"].tap()
        let card = app.buttons["collection-Real Collection"]
        XCTAssertTrue(card.waitForExistence(timeout: 180), "the real export is imported")
        return card
    }

    // MARK: Hangs

    private struct Hang {
        let duration: Double
        let frames: [String]
    }

    private func hangs() -> [Hang] {
        guard let text = try? String(contentsOf: hangLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let duration = object["duration"] as? Double else { return nil }
            return Hang(duration: duration, frames: object["frames"] as? [String] ?? [])
        }
    }

    /// Fails if the main thread stalled since `mark`; returns the new mark.
    @discardableResult
    private func assertNoHangs(since mark: Int, _ step: String) -> Int {
        let all = hangs()
        let fresh = all.dropFirst(mark)
        if !fresh.isEmpty {
            let report = fresh.map { hang in
                String(format: "%.2fs\n", hang.duration) + hang.frames.prefix(16).joined(separator: "\n")
            }.joined(separator: "\n---\n")
            XCTFail("\(step): \(fresh.count) main-thread stall(s) over the threshold\n\(report)")
        }
        return all.count
    }

    private func settle(_ seconds: TimeInterval = 1) { Thread.sleep(forTimeInterval: seconds) }

    // MARK: Flows

    /// First launch: the export lands, then the collection is entered while
    /// its metadata is still hydrating, left, entered again, sorted every
    /// way, scrolled with real images — and again once the sync is done.
    @MainActor
    func testEnteringCollectionAndSortingWhileSyncing() {
        let app = launch(reset: true)
        let card = collectionCard(app)
        settle(2)
        var mark = hangs().count

        // The whole card is the target: tap near its bottom-right corner.
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        XCTAssertTrue(app.navigationBars["Real Collection"].waitForExistence(timeout: 10), "the corner of the card opens it")
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
        settle()
        mark = assertNoHangs(since: mark, "first push into the collection")

        let syncing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Syncing' OR label BEGINSWITH 'Prices'")).firstMatch
        XCTAssertTrue(syncing.waitForExistence(timeout: 15), "hydration runs on entering")

        for i in 1...3 {
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            settle(0.5)
            card.tap()
            XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
            settle()
            mark = assertNoHangs(since: mark, "push \(i) into the collection mid-sync")
        }

        mark = sortEveryWay(app, mark: mark, label: "mid-sync")

        for _ in 0..<5 { app.swipeUp() }
        settle()
        mark = assertNoHangs(since: mark, "scrolling with real images mid-sync")

        // Let the sync finish, then the same again on a hydrated collection.
        XCTAssertTrue(syncing.waitForNonExistence(timeout: 240), "hydration finishes")
        settle(2)
        mark = assertNoHangs(since: mark, "the sync itself, while sitting on the grid")
        mark = sortEveryWay(app, mark: mark, label: "after sync")
        for _ in 0..<5 { app.swipeUp() }
        settle()
        assertNoHangs(since: mark, "scrolling with real images after sync")
    }

    private func sortEveryWay(_ app: XCUIApplication, mark: Int, label: String) -> Int {
        var mark = mark
        for option in ["Set", "Rarity", "Price", "Quantity", "Recently Added", "Name"] {
            app.buttons["sort-button"].tap()
            let item = app.buttons[option]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "sort menu shows \(option)")
            item.tap()
            settle(1.2)
            mark = assertNoHangs(since: mark, "sort by \(option) (\(label))")
        }
        return mark
    }

    /// The tap that follows launch: into the collection and onto a card the
    /// moment the grid shows, then paging fast through the viewer. The
    /// viewer's first layout in a debug build is where the runtime's type
    /// and conformance work lands; nothing of ours may be queued in front
    /// of it, and paging must stay clear.
    @MainActor
    func testOpeningTheViewerRightAfterLaunchAndPagingFast() {
        let app = launch()
        let card = collectionCard(app)
        var mark = hangs().count
        card.tap()
        let grid = app.scrollViews.firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10))
        let tile = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '#' OR label CONTAINS ' #'")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "a tile's set badge")
        tile.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 10), "viewer opens")
        settle(2)
        mark = assertNoHangs(since: mark, "into the collection and onto a card right after launch")

        let pager = app.scrollViews.element(boundBy: 0)
        for _ in 0..<8 {
            pager.swipeLeft(velocity: .fast)
        }
        settle(2)
        mark = assertNoHangs(since: mark, "paging fast through the viewer")
        for _ in 0..<3 {
            pager.swipeLeft()
            settle(1.2)
        }
        settle(1)
        assertNoHangs(since: mark, "paging slowly, resting on each card")
        app.buttons["viewer-close"].tap()
    }

    /// A card from a set the Keyrune font lacks (The List): its symbol goes
    /// through the WebKit rasterizer. Opening the viewer on it used to
    /// create the first web view on the tap, 4s of ScreenTime loading on
    /// the main thread.
    @MainActor
    func testViewerOnASetOutsideTheFont() {
        let app = launch()
        let card = collectionCard(app)
        card.tap()
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 10))
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Argothian Elder")
        // The tile's printing badge reads "1× PLST #…" (its symbol drawn).
        let badge = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'PLST #'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 15), "the List printing is in the grid")
        settle()
        var mark = hangs().count
        badge.tap()
        XCTAssertTrue(app.navigationBars["Argothian Elder"].waitForExistence(timeout: 5), "viewer opens")
        settle(4)
        mark = assertNoHangs(since: mark, "viewer on a set outside the font")
        XCTAssertTrue(app.buttons["viewer-details"].isHittable, "the viewer answers")
        app.buttons["viewer-details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail-segments"].waitForExistence(timeout: 5))
        settle(2)
        assertNoHangs(since: mark, "detail screen for that card")
    }

    /// Search: the first tap on the tab, the first tap into the field, the
    /// first characters typed and the first results.
    @MainActor
    func testSearchFirstTapAndTyping() {
        let app = launch()
        _ = collectionCard(app)
        settle(2)
        var mark = hangs().count

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        settle()
        mark = assertNoHangs(since: mark, "first tap on the Search tab")

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "keyboard comes up")
        settle()
        mark = assertNoHangs(since: mark, "first tap into the search field")

        field.typeText("gob")
        settle(1.5)
        mark = assertNoHangs(since: mark, "first characters typed")

        field.typeText("lin")
        XCTAssertTrue(app.scrollViews.firstMatch.waitForExistence(timeout: 15), "results arrive")
        settle(2)
        mark = assertNoHangs(since: mark, "results and first images")

        app.swipeUp()
        settle()
        assertNoHangs(since: mark, "scrolling search results")
    }

    /// Every screen transition once, on the real collection after launch:
    /// the Collections tab settling, All Collection and a collection pushed
    /// and popped, a card's viewer, detail and rulings, the Decks tab, a
    /// deck and its three pages, the add sheet, History and Search. Each
    /// step is checked on its own so a stall names the transition.
    @MainActor
    func testTransitionsTour() {
        let app = launch()
        let card = collectionCard(app)
        settle(3)
        var mark = hangs().count

        app.buttons["collection-all"].tap()
        XCTAssertTrue(app.navigationBars["All Collection"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "push into All Collection")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "pop back to Collections")

        card.tap()
        XCTAssertTrue(app.navigationBars["Real Collection"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "push into the collection")

        let tile = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '#' OR label CONTAINS ' #'")).element(boundBy: 4)
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "a tile's set badge")
        tile.tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 10), "viewer opens")
        settle(1.5)
        mark = assertNoHangs(since: mark, "open the viewer")

        app.buttons["viewer-details"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail-segments"].waitForExistence(timeout: 10), "detail pushes")
        settle(2)
        mark = assertNoHangs(since: mark, "push the detail screen")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Rulings'")).firstMatch.tap()
        settle()
        mark = assertNoHangs(since: mark, "rulings tab")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 5))
        settle()
        app.buttons["viewer-close"].tap()
        XCTAssertTrue(app.buttons["viewer-close"].waitForNonExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "pop detail and close the viewer")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
        mark = assertNoHangs(since: mark, "back to Collections")

        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "first tap on Decks")
        let deck = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-tile-'")).firstMatch
        if deck.waitForExistence(timeout: 5) {
            deck.tap()
            let tabs = app.segmentedControls["deck-tabs"]
            XCTAssertTrue(tabs.waitForExistence(timeout: 10), "deck opens")
            settle(2)
            mark = assertNoHangs(since: mark, "open a deck")
            tabs.buttons["Stats"].tap()
            settle(2)
            mark = assertNoHangs(since: mark, "deck Stats page")
            tabs.buttons["Details"].tap()
            settle(1.5)
            mark = assertNoHangs(since: mark, "deck Details page")
            tabs.buttons["Cards"].tap()
            settle(1.5)
            mark = assertNoHangs(since: mark, "back to deck Cards page")
            app.buttons["deck-add-cards"].tap()
            XCTAssertTrue(app.buttons["deck-add-done"].waitForExistence(timeout: 10), "add sheet")
            settle(2)
            mark = assertNoHangs(since: mark, "open the add sheet")
            app.buttons["deck-add-done"].tap()
            settle(1.5)
            mark = assertNoHangs(since: mark, "close the add sheet")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
            mark = assertNoHangs(since: mark, "pop the deck")
        }

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "first tap on History")

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "first tap on Search")

        app.tabBars.buttons["Collection"].tap()
        settle()
        assertNoHangs(since: mark, "back to the Collection tab")
    }

    /// Every screen added since the transitions tour: Settings and its
    /// pushes, the Scan tab, Search's Sets page and a set, selection in a
    /// grid and in a deck, a list's import sheet, the Decks guide, view
    /// switches and folders, Try Cards and Swaps, History's guide, and tab
    /// switching back and forth. Each step on its own, so a stall names it.
    @MainActor
    func testNewScreensTour() {
        let app = launch()
        let card = collectionCard(app)
        settle(3)
        var mark = hangs().count

        // Settings, and what it pushes.
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "open Settings")
        app.buttons["settings-backup"].tap()
        XCTAssertTrue(app.navigationBars["Backup & Restore"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "push Backup & Restore")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings-about"].tap()
        XCTAssertTrue(app.staticTexts["about-version"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "push About")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["settings-done"].tap()
        settle()
        mark = assertNoHangs(since: mark, "close Settings")

        // Selection in the real grid: long press, select more, Done.
        card.tap()
        XCTAssertTrue(app.navigationBars["Real Collection"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "push into the collection")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.3)).press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["selection-count"].waitForExistence(timeout: 5), "long press selects")
        settle()
        mark = assertNoHangs(since: mark, "start selecting in the collection")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.3)).tap()
        app.buttons["selection-all"].tap()
        settle()
        mark = assertNoHangs(since: mark, "select all 3,800 rows")
        app.buttons["selection-add"].tap()
        settle(0.5)
        mark = assertNoHangs(since: mark, "open the Add menu")
        // Close the menu without choosing: a tap above it.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertTrue(app.buttons["selection-done"].waitForExistence(timeout: 5))
        app.buttons["selection-done"].tap()
        settle()
        mark = assertNoHangs(since: mark, "leave selection")
        app.buttons["sort-button"].tap()
        app.buttons["Mana Value"].firstMatch.tap()
        settle(1.5)
        mark = assertNoHangs(since: mark, "sort by mana value")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
        mark = assertNoHangs(since: mark, "pop the collection")

        // A list and its import sheet.
        app.buttons["collections-menu"].tap()
        app.buttons["new-list-menu"].tap()
        app.alerts.textFields.firstMatch.typeText("Perf List \(Int.random(in: 1000...9999))")
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.buttons["collection-empty-import"].waitForExistence(timeout: 10))
        settle()
        mark = assertNoHangs(since: mark, "create and open a list")
        app.buttons["collection-empty-import"].tap()
        XCTAssertTrue(app.textViews["collection-import-text"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "open the import sheet")
        app.buttons["Cancel"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        settle()
        mark = assertNoHangs(since: mark, "back from the list")

        // Tabs, back and forth, twice.
        for round in 1...2 {
            for tab in ["Decks", "History", "Search", "Scan", "Collection"] {
                app.tabBars.buttons[tab].tap()
                settle(round == 1 ? 1.5 : 0.6)
                mark = assertNoHangs(since: mark, "tab \(tab), round \(round)")
            }
        }

        // Scan without a camera.
        app.tabBars.buttons["Scan"].tap()
        settle()
        mark = assertNoHangs(since: mark, "Scan tab")

        // Search: Sets, a set, back; a search; selecting in results.
        app.tabBars.buttons["Search"].tap()
        let mode = app.segmentedControls["search-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        mode.buttons["Sets"].tap()
        XCTAssertTrue(app.buttons["sets-kind"].waitForExistence(timeout: 20), "the set list loads")
        settle(1.5)
        mark = assertNoHangs(since: mark, "switch to Sets")
        app.swipeUp()
        app.swipeDown()
        settle()
        mark = assertNoHangs(since: mark, "scroll the set list")
        let firstSet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'set-row-'")).element(boundBy: 2)
        if firstSet.waitForExistence(timeout: 5) {
            firstSet.tap()
            settle(3)
            mark = assertNoHangs(since: mark, "open a set")
            app.swipeUp()
            settle(1.5)
            mark = assertNoHangs(since: mark, "scroll a set's cards")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
            mark = assertNoHangs(since: mark, "back to Sets")
        }
        mode.buttons["Cards"].tap()
        settle()
        mark = assertNoHangs(since: mark, "back to the search form")
        let field = app.searchFields.firstMatch
        field.tap()
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        field.typeText("dragon\n")
        settle(4)
        mark = assertNoHangs(since: mark, "search results")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.45)).press(forDuration: 0.8)
        settle()
        mark = assertNoHangs(since: mark, "select in search results")
        if app.buttons["selection-done"].exists { app.buttons["selection-done"].tap() }
        app.buttons["search-sort"].tap()
        app.buttons["Price"].firstMatch.tap()
        settle(3)
        mark = assertNoHangs(since: mark, "sort search results")
        app.buttons["search-clear"].firstMatch.tap()
        settle()
        mark = assertNoHangs(since: mark, "clear the search")

        // History's guide.
        app.tabBars.buttons["History"].tap()
        app.buttons["history-info"].tap()
        XCTAssertTrue(app.navigationBars["About History"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "open History's guide")
        app.buttons["history-guide-done"].tap()

        // Decks: guide, list view, a folder, a deck from real names.
        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        app.buttons["decks-info"].tap()
        XCTAssertTrue(app.navigationBars["Managing Decks"].waitForExistence(timeout: 5))
        settle()
        mark = assertNoHangs(since: mark, "open the Decks guide")
        app.buttons["decks-guide-done"].tap()
        app.buttons["decks-view-menu"].tap()
        app.buttons["List"].firstMatch.tap()
        settle()
        mark = assertNoHangs(since: mark, "switch Decks to List")
        app.buttons["decks-view-menu"].tap()
        app.buttons["Icons"].firstMatch.tap()
        settle()
        mark = assertNoHangs(since: mark, "switch Decks to Icons")
        UIPasteboard.general.string = "1 Sol Ring\n1 Arcane Signet\n1 Lightning Bolt\n1 Counterspell\n1 Llanowar Elves\n"
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        if paste.waitForExistence(timeout: 5) {
            paste.tap()
            let name = app.textFields["import-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            name.tap()
            name.typeText("Perf Deck")
            app.buttons["import-run"].tap()
            XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 30), "the deck opens")
            settle(2)
            mark = assertNoHangs(since: mark, "import and open a deck")
            app.buttons["deck-menu"].tap()
            app.buttons["deck-menu-select"].tap()
            settle()
            mark = assertNoHangs(since: mark, "select in a deck")
            app.buttons["selection-done"].tap()
            app.buttons["deck-menu"].tap()
            app.buttons["deck-menu-propose"].tap()
            settle(1.5)
            mark = assertNoHangs(since: mark, "open Try Cards")
            app.buttons["propose-done"].tap()
            app.buttons["deck-menu"].tap()
            app.buttons["deck-menu-swaps"].tap()
            settle(2)
            mark = assertNoHangs(since: mark, "push Swaps")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.segmentedControls["deck-tabs"].buttons["Details"].tap()
            settle(1.5)
            mark = assertNoHangs(since: mark, "deck Details page")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
            mark = assertNoHangs(since: mark, "pop the deck")
        }
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-folder"].tap()
        app.alerts.textFields.firstMatch.typeText("Perf Folder")
        app.alerts.buttons["Create"].tap()
        let folder = app.buttons["deck-folder-Perf Folder"].firstMatch
        if folder.waitForExistence(timeout: 5) {
            folder.tap()
            settle()
            mark = assertNoHangs(since: mark, "push a folder")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            settle()
        }
        assertNoHangs(since: mark, "back to Decks")
    }

    /// A deck's add sheet on Recommended — EDHREC's picks and the plan, cards
    /// from all over Magic, many sets the collection never showed — then a
    /// card opened from it, closed, and another opened.
    @MainActor
    func testRecommendedCardsOpenTheViewer() {
        let app = launch()
        _ = collectionCard(app)
        app.tabBars.buttons["Decks"].tap()
        let deck = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-tile-'")).firstMatch
        if deck.waitForExistence(timeout: 5) {
            deck.tap()
        } else {
            // A reset store has no deck: import the real list, which opens it.
            let fixture = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("magic-hatTests/Fixtures/KingUnderTheMountain.txt")
            UIPasteboard.general.string = (try? String(contentsOf: fixture, encoding: .utf8)) ?? ""
            app.buttons["decks-add"].tap()
            app.buttons["decks-menu-clipboard"].tap()
            let paste = app.buttons["import-paste"]
            XCTAssertTrue(paste.waitForExistence(timeout: 5))
            paste.tap()
            let nameField = app.textFields["import-name"]
            XCTAssertTrue(nameField.waitForExistence(timeout: 5))
            nameField.tap()
            nameField.typeText("King")
            app.buttons["import-run"].tap()
            if app.buttons["OK"].waitForExistence(timeout: 20) { app.buttons["OK"].tap() }
        }
        XCTAssertTrue(app.segmentedControls["deck-tabs"].waitForExistence(timeout: 30))
        settle(2)
        var mark = hangs().count

        app.buttons["deck-add-cards"].tap()
        XCTAssertTrue(app.buttons["deck-add-done"].waitForExistence(timeout: 10))
        settle(1.5)
        mark = assertNoHangs(since: mark, "open the add sheet")
        app.segmentedControls["deck-search-scope"].buttons["Recommended"].tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 60), "recommendations land")
        settle(3)
        mark = assertNoHangs(since: mark, "switch to Recommended")

        for index in [0, 2] {
            let row = rows.element(boundBy: index)
            guard row.waitForExistence(timeout: 5) else { continue }
            row.tap()
            XCTAssertTrue(app.buttons["viewer-close"].waitForExistence(timeout: 10), "viewer opens")
            settle(2)
            mark = assertNoHangs(since: mark, "open recommended card \(index) in the viewer")
            app.buttons["viewer-close"].tap()
            XCTAssertTrue(app.buttons["deck-add-done"].waitForExistence(timeout: 5))
            settle(1)
            mark = assertNoHangs(since: mark, "close the viewer \(index)")
        }
        app.buttons["deck-add-done"].tap()
    }

    /// A real deck from the real collection: the row right after the
    /// commander — the first creature — opens the viewer on itself, with
    /// real art loading in the rows and the pager.
    @MainActor
    func testDeckViewerOpensTheTappedRow() throws {
        let app = launch()
        _ = collectionCard(app)
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("magic-hatTests/Fixtures/KingUnderTheMountain.txt")
        UIPasteboard.general.string = try String(contentsOf: fixture, encoding: .utf8)

        app.tabBars.buttons["Decks"].tap()
        XCTAssertTrue(app.navigationBars["Decks"].waitForExistence(timeout: 10))
        var mark = hangs().count
        app.buttons["decks-add"].tap()
        app.buttons["decks-menu-clipboard"].tap()
        let paste = app.buttons["import-paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 5))
        paste.tap()
        let nameField = app.textFields["import-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("King")
        app.buttons["import-run"].tap()
        if app.buttons["OK"].waitForExistence(timeout: 20) { app.buttons["OK"].tap() }
        XCTAssertTrue(app.navigationBars["King"].waitForExistence(timeout: 30))
        settle(2)
        mark = assertNoHangs(since: mark, "importing and opening the deck")

        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-row-'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        for index in [1, 2, 1] {
            let row = rows.element(boundBy: index)
            let title = row.identifier.replacingOccurrences(of: "deck-row-", with: "")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "row \(index) opens the viewer on \(title)")
            settle(1.5)
            XCTAssertTrue(app.navigationBars[title].exists, "the viewer stays on \(title) once the art has loaded")
            app.buttons["viewer-close"].tap()
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        }
        mark = assertNoHangs(since: mark, "opening the viewer from deck rows")

        // The add sheet lists the whole collection, one row per card, and
        // narrows it per keystroke.
        app.buttons["deck-add-cards"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'deck-search-row-'")).firstMatch
            .waitForExistence(timeout: 15), "the collection is listed")
        settle(1.5)
        mark = assertNoHangs(since: mark, "opening the add sheet over the whole collection")
        field.tap()
        field.typeText("dr")
        settle(1.5)
        mark = assertNoHangs(since: mark, "typing in the add sheet")
        field.typeText("agon")
        settle(1.5)
        mark = assertNoHangs(since: mark, "typing more in the add sheet")
        app.swipeUp()
        settle()
        assertNoHangs(since: mark, "scrolling the add sheet")
        app.buttons["deck-add-done"].tap()
    }
}
