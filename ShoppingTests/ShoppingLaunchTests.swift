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
        XCTAssertTrue(staticText(named: "Must buy here", in: app).waitForExistence(timeout: 2))
        XCTAssertTrue(staticText(named: "Flexible here", in: app).exists)
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

    func testStoreManagementStagesRenameAndSupportsArchiveRestore() {
        let app = launchApp()
        openStoreManagement(in: app)

        let createName = app.textFields["shopping.stores.createName"]
        XCTAssertTrue(createName.waitForExistence(timeout: 2))
        createName.tap()
        createName.typeText("Neighborhood Market")
        app.buttons["Save store"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.renameName"], with: "Canceled Market")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Neighborhood Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled Market"].exists)

        app.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Rename store"].waitForExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.stores.renameName"], with: "Local Market")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Local Market"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Neighborhood Market"].exists)

        app.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Archived"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Restore"].exists)
        attachScreenshot(named: "Store Management Archived", app: app)
        app.buttons["Restore"].tap()
        XCTAssertFalse(app.staticTexts["Archived"].exists)
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 2))
    }

    func testCancelingInlineStoreAndParentAddCreatesNeitherStoreNorNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled grocery")
        app.buttons["shopping.tags.addStore"].tap()
        XCTAssertTrue(app.navigationBars["Add store"].waitForExistence(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        storeName.tap()
        storeName.typeText("Canceled store")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Add one-time grocery"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
        openStoreManagement(in: app)
        XCTAssertFalse(app.staticTexts["Canceled store"].exists)
    }

    func testSavingInlineStoreSelectsItButParentCancelCreatesNoNeed() {
        let app = launchApp()
        openOneTimeAdd(in: app, groceryName: "Canceled tagged grocery")
        app.buttons["shopping.tags.addStore"].tap()
        XCTAssertTrue(app.navigationBars["Add store"].waitForExistence(timeout: 2))
        let storeName = app.textFields["shopping.tags.storeName"]
        storeName.tap()
        storeName.typeText("Corner Shop")
        app.buttons["Save store"].tap()

        XCTAssertTrue(app.navigationBars["Add one-time grocery"].waitForExistence(timeout: 2))
        let selectedStore = app.switches["Corner Shop"]
        XCTAssertTrue(selectedStore.waitForExistence(timeout: 2))
        XCTAssertEqual(selectedStore.value as? String, "1")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))

        openStoreManagement(in: app)
        XCTAssertTrue(app.staticTexts["Corner Shop"].waitForExistence(timeout: 2))
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

    private func openStoreManagement(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].waitForExistence(timeout: 2))
    }

    private func openOneTimeAdd(in app: XCUIApplication, groceryName: String) {
        XCTAssertTrue(app.buttons["shopping.addGrocery"].waitForExistence(timeout: 5))
        app.buttons["shopping.addGrocery"].tap()
        XCTAssertTrue(app.navigationBars["Add one-time grocery"].waitForExistence(timeout: 2))
        let name = app.textFields["Grocery name"]
        name.tap()
        name.typeText(groceryName)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func staticText(named label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }
}
