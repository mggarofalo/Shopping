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
        name.tap()
        name.typeText("Pantry")
        app.buttons["Save category"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))

        app.staticTexts["Pantry"].swipeLeft()
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.navigationBars["Rename category"].waitForExistence(timeout: 2))
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

    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        field.typeText(text)
    }
}
