import XCTest

final class PerformanceFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testRepresentativeLoadedFlowThreeTimes() {
        let runCount = Int(ProcessInfo.processInfo.environment["SHOPPING_PERFORMANCE_RUNS"] ?? "") ?? 3
        for run in 1...runCount {
            XCTContext.runActivity(named: "Loaded device run \(run)") { _ in
                let groceries = launchPerformanceFixture()
                exerciseGroceries(in: groceries)
                groceries.terminate()

                let catalog = launchPerformanceFixture()
                exerciseCatalog(in: catalog)
                catalog.terminate()

                let management = launchPerformanceFixture()
                exerciseManagement(in: management)
                management.terminate()
            }
        }
    }

    private func launchPerformanceFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_PERFORMANCE_FIXTURE"] = "performance"
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

        app.buttons["shopping.catalog.available"].tap()
        app.buttons["Store 04"].tap()
        app.buttons["shopping.catalog.available"].tap()
        app.buttons["All items"].tap()

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
}
