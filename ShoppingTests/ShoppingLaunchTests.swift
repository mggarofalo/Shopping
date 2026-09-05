import XCTest

final class ShoppingLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsEmptyGroceriesAndConnectedTabs() {
        let app = launchApp()
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shopping.addGrocery"].exists)
        XCTAssertTrue(app.tabBars.buttons["Catalog"].exists)
        XCTAssertTrue(app.tabBars.buttons["Settings"].exists)
        attachScreenshot(named: "Empty Groceries", app: app)

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 2))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
    }

    func testPopulatedCostcoNavigationAtAccessibilitySize() {
        let app = launchApp(fixture: "populated", accessibilitySize: true)
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 5))
        let storeMenu = app.buttons["shopping.store.menu"]
        XCTAssertTrue(storeMenu.waitForExistence(timeout: 3))
        storeMenu.tap()
        let costco = app.buttons["Costco"]
        XCTAssertTrue(costco.waitForExistence(timeout: 2))
        costco.tap()
        XCTAssertTrue(app.staticTexts["Must buy here"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Flexible here"].exists)
        XCTAssertTrue(app.buttons["shopping.filters"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Carted")).firstMatch.exists)
        attachScreenshot(named: "Populated Costco Accessibility Large", app: app)
    }

    func testOneTimeAddSavesWithoutStoreSetupAndDoesNotPolluteCatalog() {
        let app = launchApp()
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add one-time grocery"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["This grocery won’t be remembered in Catalog."].exists)
        let name = app.textFields["Grocery name"]
        XCTAssertTrue(name.exists)
        name.tap()
        name.typeText("Fresh basil")
        app.buttons["Add"].tap()
        XCTAssertTrue(app.staticTexts["Fresh basil"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.staticTexts["No remembered groceries"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Fresh basil"].exists)
    }

    private func launchApp(fixture: String? = nil, accessibilitySize: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingUITest-\(UUID().uuidString).sqlite").path
        if let fixture { app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = fixture }
        if accessibilitySize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
        }
        app.launch()
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
