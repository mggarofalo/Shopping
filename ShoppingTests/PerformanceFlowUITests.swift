import XCTest

final class PerformanceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRepresentativeLoadedFlowThreeTimes() {
        let runCount = Int(ProcessInfo.processInfo.environment["SHOPPING_PERFORMANCE_RUNS"] ?? "") ?? 3
        for run in 1...runCount {
            XCTContext.runActivity(named: "Loaded device run \(run)") { _ in
                let runID = "representative-\(run)"
                seedPerformanceFixture(runID: runID)

                let groceries = launchPerformanceFixture(runID: runID)
                exerciseGroceries(in: groceries)
                groceries.terminate()

                let catalog = launchPerformanceFixture(runID: runID)
                exerciseCatalog(in: catalog)
                catalog.terminate()

                let management = launchPerformanceFixture(runID: runID)
                exerciseManagement(in: management)
                management.terminate()
            }
        }
    }

    func testCatalogTraceFlow() {
        let runID = "trace-catalog"
        seedPerformanceFixture(runID: runID)
        let app = launchPerformanceFixture(runID: runID)
        Thread.sleep(forTimeInterval: 8)
        exerciseCatalog(in: app)
    }

    private func seedPerformanceFixture(runID: String) {
        let app = launchPerformanceFixture(runID: runID, reset: true)
        app.terminate()
    }

    private func launchPerformanceFixture(runID: String, reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_PERFORMANCE_FIXTURE"] = "performance"
        app.launchEnvironment["SHOPPING_PERFORMANCE_RUN_ID"] = runID
        if reset {
            app.launchEnvironment["SHOPPING_PERFORMANCE_RESET"] = "1"
        }
        app.launch()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 15))
        return app
    }

    private func exerciseGroceries(in app: XCUIApplication) {
        app.buttons["shopping.store.menu"].tap()
        let store = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Store 04", "shopping.store.menu"
        )).firstMatch
        XCTAssertTrue(store.waitForExistence(timeout: 3))
        store.tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("item 01")
        clearSearch(in: app)
    }

    private func exerciseCatalog(in app: XCUIApplication) {
        tapTab("Catalog", in: app)
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 5))
        let list = app.collectionViews["shopping.catalog.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))

        app.buttons["shopping.catalog.grouping"].tap()
        app.buttons["Store"].tap()
        app.buttons["shopping.catalog.grouping"].tap()
        app.buttons["Category"].tap()

        app.buttons["shopping.catalog.filters"].tap()
        app.buttons["shopping.catalog.filters.include.\(storeID(named: "Store 04", in: app))"].tap()
        app.buttons["Done"].tap()
        app.buttons["shopping.catalog.filters"].tap()
        app.buttons["Reset"].tap()
        app.buttons["Done"].tap()

        enterSelectionMode(in: app)
        app.buttons["shopping.catalog.selectAll"].tap()
        app.buttons["shopping.catalog.batchAdd"].tap()
        let confirmation = app.sheets["Add selected items to list?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Add to list"].tap()
        let result = app.alerts["Catalog update complete"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.buttons["OK"].tap()
        if app.buttons["Done"].exists {
            app.buttons["Done"].tap()
        }

        let firstRow = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "shopping.catalog.item."
        )).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        firstRow.tap()
        XCTAssertTrue(app.navigationBars["Edit catalog item"].waitForExistence(timeout: 3))
        let notes = app.textFields["shopping.catalog.notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 3))
        notes.tap()
        notes.typeKey("a", modifierFlags: .command)
        notes.typeText("Performance note")
        app.buttons["shopping.catalog.save"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))

        list.swipeUp()
        list.swipeUp()
        list.swipeDown()
        list.swipeDown()

        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("item 04")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Catalog item 04")).firstMatch.waitForExistence(timeout: 3))
        clearSearch(in: app)
    }

    private func storeID(named name: String, in app: XCUIApplication) -> String {
        let button = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier BEGINSWITH %@", name, "shopping.catalog.filters.include."
        )).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        return String(button.identifier.dropFirst("shopping.catalog.filters.include.".count))
    }

    private func exerciseManagement(in app: XCUIApplication) {
        tapTab("Settings", in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].waitForExistence(timeout: 3))
        app.collectionViews.firstMatch.swipeUp()
        app.collectionViews.firstMatch.swipeDown()
        app.navigationBars["Stores"].buttons.firstMatch.tap()

        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        app.collectionViews.firstMatch.swipeUp()
        app.collectionViews.firstMatch.swipeUp()
        app.collectionViews.firstMatch.swipeDown()
        app.navigationBars["Categories"].buttons.firstMatch.tap()
    }

    private func clearSearch(in app: XCUIApplication) {
        let clear = app.buttons["Clear text"]
        XCTAssertTrue(clear.waitForExistence(timeout: 2))
        clear.tap()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    }

    private func tapTab(_ name: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        if tab.isHittable {
            tab.tap()
        } else {
            tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func enterSelectionMode(in app: XCUIApplication) {
        let select = app.buttons["shopping.catalog.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 2))
        select.tap()
    }
}
