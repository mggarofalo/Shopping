import XCTest

final class CategoryManagementUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCategoryCreateStagedRenameAndConfirmedRemoval() {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingCategoryUITest-\(UUID().uuidString).sqlite").path
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        app.buttons["shopping.categories.add"].tap()
        XCTAssertTrue(app.navigationBars["Add category"].waitForExistence(timeout: 2))
        let name = app.textFields["shopping.categories.name"]
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        name.typeText("Pantry")
        app.buttons["Save category"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))

        app.staticTexts["Pantry"].swipeLeft()
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Rename category"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
        replaceText(in: app.textFields["shopping.categories.name"], with: "Canceled category")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Canceled category"].exists)

        app.staticTexts["Pantry"].swipeLeft()
        app.buttons["Edit"].tap()
        replaceText(in: app.textFields["shopping.categories.name"], with: "Dry goods")
        app.buttons["Save category"].tap()
        XCTAssertTrue(app.staticTexts["Dry goods"].waitForExistence(timeout: 2))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Category management"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.staticTexts["Dry goods"].swipeRight()
        app.buttons["Delete"].tap()
        let confirmation = app.sheets["Delete Dry goods?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(confirmation.staticTexts.matching(NSPredicate(format: "label CONTAINS %@",
            "Groceries and catalog items will remain and become Uncategorized.")).firstMatch.exists)
        confirmation.buttons["Delete category"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["Dry goods"].waitForExistence(timeout: 2))
        app.navigationBars["Categories"].buttons.firstMatch.tap()
        app.tabBars.buttons["Groceries"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["shopping.emptyState"].waitForExistence(timeout: 2))
    }

    func testCategoryBatchSelectAllPresentsOneRedDeleteConfirmation() {
        let app = launchPopulated()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Categories"].tap()
        XCTAssertTrue(app.navigationBars["Categories"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Categories", identifier: "shopping.categories.select")
        app.buttons["shopping.categories.batchActions"].tap()
        XCTAssertTrue(app.buttons["Select All"].waitForExistence(timeout: 2))
        app.buttons["Select All"].tap()
        app.buttons["shopping.categories.batchActions"].tap()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        let confirmation = app.sheets["Delete selected categories?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        XCTAssertTrue(confirmation.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "will be permanently deleted")
        ).firstMatch.exists)
        XCTAssertTrue(confirmation.buttons["Delete"].exists)
        confirmation.buttons["Delete"].tap()
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()
    }

    func testStoreAndCatalogBatchActionsReflectSelectedState() {
        let app = launchPopulated()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Stores"].tap()
        XCTAssertTrue(app.navigationBars["Stores"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Stores", identifier: "shopping.stores.select")
        app.buttons["shopping.stores.batchActions"].tap()
        app.buttons["Select All"].tap()
        app.buttons["shopping.stores.batchActions"].tap()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Archive"].tap()
        XCTAssertTrue(app.sheets["Archive selected stores?"].waitForExistence(timeout: 2))
        app.sheets.buttons["Archive"].tap()
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()

        enterSelectionMode(app, navigationTitle: "Stores", identifier: "shopping.stores.select")
        app.buttons["shopping.stores.batchActions"].tap()
        app.buttons["Select All"].tap()
        app.buttons["shopping.stores.batchActions"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Archive"].exists)
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.sheets["Restore selected stores?"].waitForExistence(timeout: 2))
        app.sheets.buttons["Restore"].tap()
        XCTAssertTrue(app.alerts["Batch update complete"].waitForExistence(timeout: 3))
        app.alerts.buttons["OK"].tap()

        app.navigationBars["Stores"].buttons.firstMatch.tap()
        app.tabBars.buttons["Catalog"].tap()
        XCTAssertTrue(app.navigationBars["Catalog"].waitForExistence(timeout: 3))
        enterSelectionMode(app, navigationTitle: "Catalog", identifier: "shopping.catalog.select")
        app.buttons["shopping.catalog.batchActions"].tap()
        app.buttons["Select All"].tap()
        app.buttons["shopping.catalog.batchActions"].tap()
        XCTAssertTrue(app.buttons["Archive"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Delete"].exists)
    }

    private func launchPopulated() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHOPPING_UI_TEST_STORE_PATH"] = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShoppingBatchUITest-\(UUID().uuidString).sqlite").path
        app.launchEnvironment["SHOPPING_UI_TEST_FIXTURE"] = "populated"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 5))
        return app
    }

    private func enterSelectionMode(_ app: XCUIApplication, navigationTitle: String, identifier: String) {
        let select = app.buttons[identifier]
        if !select.exists {
            app.navigationBars[navigationTitle].buttons["More"].tap()
        }
        let visibleSelect = select.exists ? select : app.buttons["Select"]
        XCTAssertTrue(visibleSelect.waitForExistence(timeout: 2))
        visibleSelect.tap()
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }
}
