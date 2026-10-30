import XCTest

/// Every searched list keeps one pinned search field across tab switches, pushes and scrolling.
final class SearchPresentationUITests: XCTestCase {
    func testTabRoundTripsKeepSearchVisibleOnLongLists() {
        let app = launchApp(fixture: "performance")
        assertSearchField("Search groceries", in: app, screen: "Groceries at launch")

        for round in 1...3 {
            app.tabBars.buttons["Catalog"].tap()
            XCTAssertTrue(app.navigationBars["Catalog"].existsOrAppears(timeout: 5))
            assertSearchField("Search catalog", in: app, screen: "Catalog round \(round)")
            app.tabBars.buttons["Groceries"].tap()
            XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 5))
            assertSearchField("Search groceries", in: app, screen: "Groceries round \(round)")
        }

        app.tabBars.buttons["Catalog"].tap()
        app.swipeUp()
        assertSearchField("Search catalog", in: app, screen: "Catalog after scrolling")
        app.tabBars.buttons["Groceries"].tap()
        app.swipeUp()
        assertSearchField("Search groceries", in: app, screen: "Groceries after scrolling")
        app.tabBars.buttons["Catalog"].tap()
        assertSearchField("Search catalog", in: app, screen: "Scrolled Catalog after round trip")
    }

    func testPushedAndPresentedSearchesMatchTabSearch() {
        let app = launchApp(fixture: "populated")
        openCart(in: app, titled: "In cart")
        assertSearchField("Search groceries", in: app, screen: "In cart")
        app.tabBars.buttons["Catalog"].tap()
        assertSearchField("Search catalog", in: app, screen: "Catalog with In cart pushed")
        app.tabBars.buttons["Groceries"].tap()
        assertSearchField("Search groceries", in: app, screen: "In cart after tab round trip")
        app.navigationBars["In cart"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 3))
        assertSearchField("Search groceries", in: app, screen: "Groceries after In cart")

        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].existsOrAppears(timeout: 3))
        assertSearchField("Search catalog", in: app, screen: "Add to Groceries searching")
        // Active native search hides the sheet toolbar until search is dismissed.
        let closeSearch = app.buttons["Close"]
        if closeSearch.exists {
            closeSearch.tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        assertSearchField("Search catalog", in: app, screen: "Add to Groceries")
        let cancel = app.buttons["shopping.grocery.catalogCancel"]
        XCTAssertTrue(cancel.existsOrAppears(timeout: 3))
        cancel.tap()
        XCTAssertTrue(app.navigationBars["Add to Groceries"].waitForNonExistence(timeout: 3))
        app.tabBars.buttons["Catalog"].tap()
        assertSearchField("Search catalog", in: app, screen: "Catalog after Add to Groceries")
    }

    func testPersonalCartShowsTheSearchThatFiltersIt() {
        let app = launchApp(fixture: "populated", personalCart: true)
        openCart(in: app, titled: "My cart")
        assertSearchField("Search groceries", in: app, screen: "My cart")
        app.tabBars.buttons["Catalog"].tap()
        assertSearchField("Search catalog", in: app, screen: "Catalog with My cart pushed")
        app.tabBars.buttons["Groceries"].tap()
        assertSearchField("Search groceries", in: app, screen: "My cart after tab round trip")
    }

    private func launchApp(fixture: String, personalCart: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingSearchPresentationUITest-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture
        if personalCart { app.launchEnvironment["SHOPPING_UI_TEST_PERSONAL_CART"] = "1" }
        app.launch()
        addTeardownBlock { app.terminate() }
        XCTAssertTrue(app.navigationBars["Groceries"].existsOrAppears(timeout: 10))
        return app
    }

    /// The cart link is a Groceries toolbar item; its count varies by fixture.
    private func openCart(in app: XCUIApplication, titled title: String) {
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "In cart (")).firstMatch
        XCTAssertTrue(link.existsOrAppears(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars[title].existsOrAppears(timeout: 3))
    }

    /// The field must be on screen without a pull-down gesture, in the top navigation drawer.
    private func assertSearchField(_ prompt: String, in app: XCUIApplication, screen: String) {
        let field = app.searchFields[prompt]
        let found = field.existsOrAppears(timeout: 3)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screen
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(found, "\(screen): \(prompt) is missing")
        guard found else { return }
        XCTAssertTrue(field.isHittable, "\(screen): \(prompt) is not hittable")
        XCTAssertLessThan(field.frame.maxY, app.frame.midY, "\(screen): \(prompt) is not in the top drawer")
    }
}
